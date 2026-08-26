
/************************************************************************************
 If not stated otherwise in this file or this component's LICENSE file the
 following copyright and licenses apply:

 Copyright 2026 Comcast

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
**************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdbool.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <ctype.h>
#include <time.h>
#include <stdint.h>
#include <errno.h>
#include <rbus/rbus.h>
#include <mosquitto.h>

#define MAX_VAPS 32
#define MAX_NAME 256
#define MAX_CLIENT_DB 512
#define SUBS_PER_VAP 4

#define MQTT_PUBLISH_PERIOD_SEC 30
#define MQTT_STALE_BUFFER_SEC 10
#define MQTT_HOST_DEFAULT "96.102.99.5"
#define MQTT_PORT_DEFAULT 443
#define MQTT_TOPIC_DEFAULT "rdkb_telemetry_poc_topic"
#define MQTT_CLIENT_ID_PREFIX "xwifi_dev"

#ifndef UNREFERENCED_PARAMETER
#define UNREFERENCED_PARAMETER(_p_) (void)(_p_)
#endif

#define WIFI_DIAGDATA_SUB_DBG(msg, ...) \
    wifi_diagdata_sub_dbg_print("%s:%d  " msg "\n", __func__, __LINE__, ##__VA_ARGS__);

static volatile sig_atomic_t g_running = 1;
static rbusHandle_t g_handle = NULL;
static rbusEventSubscription_t *g_subs = NULL;
static int g_sub_count = 0;
static struct mosquitto *g_mosq = NULL;
static unsigned long g_diag_events_received = 0;

typedef struct client_record {
    bool in_use;
    bool active;
    char event_name[MAX_NAME];
    char mac[32];
    char rssi[16];
    char snr[16];
    char status[16];
    char reason[64];
    time_t last_update;
} client_record;

static client_record g_client_db[MAX_CLIENT_DB];

static void __attribute__((unused)) wifi_diagdata_sub_dbg_print(char const *format, ...)
{
    va_list list;

    va_start(list, format);
    vprintf(format, list);
    va_end(list);
}

static void copy_string_safe(char *dst, size_t dst_len, char const *src)
{
    if (!dst || dst_len == 0) {
        return;
    }

    if (!src) {
        dst[0] = '\0';
        return;
    }

    snprintf(dst, dst_len, "%s", src);
}

static void trim_whitespace_safe(char *str)
{
    char *start;
    char *end;

    if (!str) {
        return;
    }

    /* Skip leading whitespace */
    start = str;
    while (*start && isspace((unsigned char)*start)) {
        start++;
    }
    if (start != str) {
        memmove(str, start, strlen(start) + 1);
    }

    /* Remove trailing whitespace */
    end = str + strlen(str);
    while (end > str && isspace((unsigned char)end[-1])) {
        *--end = '\0';
    }
}

static bool parse_vap_from_event_name(char const *event_name, int *vap)
{
    if (!event_name || !vap) {
        return false;
    }

    return sscanf(event_name, "Device.WiFi.AccessPoint.%d.", vap) == 1;
}

static bool mqtt_init(void)
{
    char client_id[64];
    int rc;

    mosquitto_lib_init();

    snprintf(client_id, sizeof(client_id), "%s_%d", MQTT_CLIENT_ID_PREFIX, getpid());
    g_mosq = mosquitto_new(client_id, true, NULL);
    if (!g_mosq) {
        printf("[MQTT] mosquitto_new failed\n");
        mosquitto_lib_cleanup();
        return false;
    }

    rc = mosquitto_connect(g_mosq, MQTT_HOST_DEFAULT, MQTT_PORT_DEFAULT, 60);
    if (rc != MOSQ_ERR_SUCCESS) {
        printf("[MQTT] connect failed rc=%d\n", rc);
        mosquitto_destroy(g_mosq);
        g_mosq = NULL;
        mosquitto_lib_cleanup();
        return false;
    }

    rc = mosquitto_loop_start(g_mosq);
    if (rc != MOSQ_ERR_SUCCESS) {
        printf("[MQTT] loop_start failed rc=%d\n", rc);
        mosquitto_disconnect(g_mosq);
        mosquitto_destroy(g_mosq);
        g_mosq = NULL;
        mosquitto_lib_cleanup();
        return false;
    }

    printf("[MQTT] connected to %s:%d topic=%s\n", MQTT_HOST_DEFAULT, MQTT_PORT_DEFAULT,
        MQTT_TOPIC_DEFAULT);
    return true;
}

/* Each client entry in the JSON report is at most ~170 bytes. Size the
 * buffer so it can hold all MAX_CLIENT_DB entries plus array framing. */
#define MQTT_TIMESTAMP_LEN     20
#define MQTT_REPORT_ENTRY_MAX  170
#define MQTT_REPORT_BUF_SIZE   (MAX_CLIENT_DB * MQTT_REPORT_ENTRY_MAX + 64)

static void mqtt_publish_report(char const *report, int len)
{
    int rc;

    if (!g_mosq || !report || len <= 0) {
        return;
    }

    rc = mosquitto_publish(g_mosq, NULL, MQTT_TOPIC_DEFAULT, len, report, 0, false);
    if (rc != MOSQ_ERR_SUCCESS) {
        printf("[MQTT] publish failed rc=%d\n", rc);
    }
}

static bool format_publish_timestamp(char *timestamp, size_t timestamp_len)
{
    time_t now;
    struct tm utc_time;

    if (!timestamp || timestamp_len < MQTT_TIMESTAMP_LEN) {
        return false;
    }

    now = time(NULL);
    if (now == (time_t)-1 || !gmtime_r(&now, &utc_time)) {
        return false;
    }

    return strftime(timestamp, timestamp_len, "%Y-%m-%d %H:%M:%S", &utc_time) > 0;
}

static client_record *find_or_create_client_record(char const *event_name, char const *mac)
{
    int free_idx = -1;

    if (!event_name || !mac) {
        return NULL;
    }

    /* Reuse an existing slot when the same VAP/MAC pair appears again. */
    for (int i = 0; i < MAX_CLIENT_DB; i++) {
        if (!g_client_db[i].in_use) {
            if (free_idx < 0) {
                free_idx = i;
            }
            continue;
        }

        if (strcmp(g_client_db[i].event_name, event_name) == 0 &&
            strcmp(g_client_db[i].mac, mac) == 0) {
            return &g_client_db[i];
        }
    }

    if (free_idx < 0) {
        return NULL;
    }

    memset(&g_client_db[free_idx], 0, sizeof(g_client_db[free_idx]));
    g_client_db[free_idx].in_use = true;
    copy_string_safe(g_client_db[free_idx].event_name, sizeof(g_client_db[free_idx].event_name),
        event_name);
    copy_string_safe(g_client_db[free_idx].mac, sizeof(g_client_db[free_idx].mac), mac);

    return &g_client_db[free_idx];
}

static void publish_client_db_snapshot(void)
{
    int active_count = 0;
    time_t now = time(NULL);
    const int stale_threshold = MQTT_PUBLISH_PERIOD_SEC + MQTT_STALE_BUFFER_SEC;
    char timestamp[MQTT_TIMESTAMP_LEN] = { 0 };
    char *buf = NULL;
    int pos = 0;

    if (!format_publish_timestamp(timestamp, sizeof(timestamp))) {
        printf("[MQTT] Failed to create publish timestamp\n");
        return;
    }

    buf = (char *)malloc(MQTT_REPORT_BUF_SIZE);
    if (!buf) {
        printf("[MQTT] Failed to allocate report buffer\n");
        return;
    }

    pos = snprintf(buf, MQTT_REPORT_BUF_SIZE, "[{\"Time\":\"%s\"}", timestamp);
    if (pos < 0 || pos >= MQTT_REPORT_BUF_SIZE) {
        printf("[MQTT] Failed to build report timestamp\n");
        free(buf);
        return;
    }

    for (int i = 0; i < MAX_CLIENT_DB; i++) {
        int n;

        if (!g_client_db[i].in_use || !g_client_db[i].active) {
            continue;
        }

        /* Skip clients not updated within the last polling period + buffer */
        if (g_client_db[i].last_update > 0 && (now - g_client_db[i].last_update) > stale_threshold) {
            continue;
        }

        n = snprintf(buf + pos, MQTT_REPORT_BUF_SIZE - pos,
            ",{\"mac\":\"%s\",\"rssi\":\"%s\",\"snr\":\"%s\",\"status\":\"%s\",\"reason\":\"%s\"}",
            g_client_db[i].mac,
            g_client_db[i].rssi[0]   ? g_client_db[i].rssi   : "NA",
            g_client_db[i].snr[0]    ? g_client_db[i].snr    : "NA",
            g_client_db[i].status[0] ? g_client_db[i].status : "success",
            g_client_db[i].reason[0] ? g_client_db[i].reason : "none");

        if (n < 0 || (pos + n) >= (MQTT_REPORT_BUF_SIZE - 2)) {
            printf("[MQTT] Report buffer full at %d clients, truncating\n", active_count);
            break;
        }

        pos += n;
        active_count++;
    }

    buf[pos++] = ']';
    buf[pos]   = '\0';

    if (active_count > 0) {
        /* Single publish for the entire snapshot */
        mqtt_publish_report(buf, pos);

        printf("[MQTT] Publish tick: events=%lu active_clients=%d payload_bytes=%d\n",
            g_diag_events_received, active_count, pos);
    } else {
        printf("[MQTT] Publish skipped: no active clients to report\n");
    }

    if (g_diag_events_received == 0) {
        printf("[DiagData] No events received yet. Verify VAP index and subscription interval.\n");
    }

    free(buf);
}

static void mqtt_cleanup(void)
{
    if (!g_mosq) {
        return;
    }

    mosquitto_disconnect(g_mosq);
    mosquitto_loop_stop(g_mosq, true);
    mosquitto_destroy(g_mosq);
    g_mosq = NULL;
    mosquitto_lib_cleanup();
}

static bool extract_json_value(char const *start, char const *key, char *out, size_t out_len)
{
    char const *pos;
    char const *val_start;
    char const *val_end;
    size_t len;

    if (!start || !key || !out || out_len == 0) {
        return false;
    }

    pos = strstr(start, key);
    if (!pos) {
        return false;
    }

    val_start = pos + strlen(key);
    while (*val_start && isspace((unsigned char)*val_start)) {
        val_start++;
    }

    /* Support both quoted and unquoted values in the DiagData payload. */
    if (*val_start == '"') {
        val_start++;
        val_end = strchr(val_start, '"');
        if (!val_end || val_end <= val_start) {
            return false;
        }
    } else {
        val_end = val_start;
        while (*val_end && *val_end != ',' && *val_end != '}' && *val_end != ']' &&
            !isspace((unsigned char)*val_end)) {
            val_end++;
        }
        if (val_end <= val_start) {
            return false;
        }
    }

    len = (size_t)(val_end - val_start);
    if (len >= out_len) {
        len = out_len - 1;
    }

    memcpy(out, val_start, len);
    out[len] = '\0';
    return true;
}

static void derive_client_status_and_reason(char const *active, bool got_active,
    char const *auth_state, bool got_auth_state,
    char const *auth_failures, bool got_auth_failures,
    char const *disassociations, bool got_disassociations,
    char *status, size_t status_len,
    char *reason, size_t reason_len)
{
    int active_val = 0;
    int auth_state_val = 0;
    int auth_failures_val = 0;
    int disassociations_val = 0;
    char *end_ptr;

    if (!status || status_len == 0 || !reason || reason_len == 0) {
        return;
    }

    status[0] = '\0';
    reason[0] = '\0';

    /* Parse integer values with error checking */
    if (got_active && active) {
        active_val = (int)strtol(active, &end_ptr, 10);
        if (end_ptr == active) {
            active_val = 0;
        }
    }
    if (got_auth_state && auth_state) {
        auth_state_val = (int)strtol(auth_state, &end_ptr, 10);
        if (end_ptr == auth_state) {
            auth_state_val = 0;
        }
    }
    if (got_auth_failures && auth_failures) {
        auth_failures_val = (int)strtol(auth_failures, &end_ptr, 10);
        if (end_ptr == auth_failures) {
            auth_failures_val = 0;
        }
    }
    if (got_disassociations && disassociations) {
        disassociations_val = (int)strtol(disassociations, &end_ptr, 10);
        if (end_ptr == disassociations) {
            disassociations_val = 0;
        }
    }

    /* Active=1 indicates connected/success state */
    if (got_active && active_val == 1) {
        copy_string_safe(status, status_len, "success");
        copy_string_safe(reason, reason_len, "none");
        return;
    }

    copy_string_safe(status, status_len, "failure");

    /* Derive reason from available failure counters */
    if (got_auth_failures && auth_failures_val > 0) {
        copy_string_safe(reason, reason_len, "authentication_failures");
    } else if (got_auth_state && auth_state_val == 0) {
        copy_string_safe(reason, reason_len, "authentication_state_failed");
    } else if (got_disassociations && disassociations_val > 0) {
        copy_string_safe(reason, reason_len, "disassociated");
    } else if (got_active && active_val == 0) {
        copy_string_safe(reason, reason_len, "inactive");
    } else {
        copy_string_safe(reason, reason_len, "unknown");
    }
}

static void update_client_db_from_payload(char const *payload, char const *event_name)
{
    char const *cursor;
    char const *next_cursor;
    char mac[32];
    char rssi[16];
    char snr[16];
    char active[8];
    char auth_state[8];
    char auth_failures[16];
    char disassociations[16];
    char status[16];
    char reason[64];
    int client_idx = 0;
    int updated_count = 0;

    if (!payload) {
        return;
    }

    cursor = strstr(payload, "\"MAC\":");
    if (!cursor) {
        return;
    }

    /* Walk each client object in the payload and update the local cache. */
    while (cursor) {
        bool got_mac;
        bool got_rssi;
        bool got_snr;
        bool got_active;
        bool got_auth_state;
        bool got_auth_failures;
        bool got_disassociations;
        char const *rssi_pos;
        char const *snr_pos;
        char const *active_pos;
        char const *auth_state_pos;
        char const *auth_failures_pos;
        char const *disassociations_pos;

        next_cursor = strstr(cursor + 1, "\"MAC\":");

        memset(mac, 0, sizeof(mac));
        memset(rssi, 0, sizeof(rssi));
        memset(snr, 0, sizeof(snr));
        memset(active, 0, sizeof(active));
        memset(auth_state, 0, sizeof(auth_state));
        memset(auth_failures, 0, sizeof(auth_failures));
        memset(disassociations, 0, sizeof(disassociations));
        memset(status, 0, sizeof(status));
        memset(reason, 0, sizeof(reason));

        got_mac = extract_json_value(cursor, "\"MAC\":", mac, sizeof(mac));

        rssi_pos = strstr(cursor, "\"RSSI\":");
        snr_pos = strstr(cursor, "\"SNR\":");
        active_pos = strstr(cursor, "\"Active\":");
        auth_state_pos = strstr(cursor, "\"AuthenticationState\":");
        auth_failures_pos = strstr(cursor, "\"AuthenticationFailures\":");
        disassociations_pos = strstr(cursor, "\"Disassociations\":");

        /* Ensure fields belong to current client object, not the next */
        if (next_cursor && rssi_pos && rssi_pos > next_cursor) {
            rssi_pos = NULL;
        }
        if (next_cursor && snr_pos && snr_pos > next_cursor) {
            snr_pos = NULL;
        }
        if (next_cursor && active_pos && active_pos > next_cursor) {
            active_pos = NULL;
        }
        if (next_cursor && auth_state_pos && auth_state_pos > next_cursor) {
            auth_state_pos = NULL;
        }
        if (next_cursor && auth_failures_pos && auth_failures_pos > next_cursor) {
            auth_failures_pos = NULL;
        }
        if (next_cursor && disassociations_pos && disassociations_pos > next_cursor) {
            disassociations_pos = NULL;
        }

        got_rssi = rssi_pos ? extract_json_value(rssi_pos, "\"RSSI\":", rssi, sizeof(rssi)) : false;
        got_snr = snr_pos ? extract_json_value(snr_pos, "\"SNR\":", snr, sizeof(snr)) : false;
        got_active = active_pos ? extract_json_value(active_pos, "\"Active\":", active, sizeof(active)) : false;
        got_auth_state = auth_state_pos ? extract_json_value(auth_state_pos,
            "\"AuthenticationState\":", auth_state, sizeof(auth_state)) : false;
        got_auth_failures = auth_failures_pos ? extract_json_value(auth_failures_pos,
            "\"AuthenticationFailures\":", auth_failures, sizeof(auth_failures)) : false;
        got_disassociations = disassociations_pos ? extract_json_value(disassociations_pos,
            "\"Disassociations\":", disassociations, sizeof(disassociations)) : false;

        derive_client_status_and_reason(active, got_active, auth_state, got_auth_state,
            auth_failures, got_auth_failures, disassociations, got_disassociations,
            status, sizeof(status), reason, sizeof(reason));

        if (got_mac) {
            if (client_idx == 0) {
                printf("\n===== DiagData Event =====\n");
                printf("event: %s\n", event_name ? event_name : "unknown");
            }
            client_idx++;
            printf("client[%d] MAC=%s RSSI=%s SNR=%s STATUS=%s REASON=%s\n", client_idx, mac,
                got_rssi ? rssi : "NA", got_snr ? snr : "NA",
                status[0] ? status : "unknown", reason[0] ? reason : "unknown");
        }

        if (got_mac) {
            client_record *rec = find_or_create_client_record(event_name ? event_name : "unknown", mac);
            if (rec) {
                rec->active = (got_active && strcmp(active, "1") == 0);
                if (got_rssi) {
                    copy_string_safe(rec->rssi, sizeof(rec->rssi), rssi);
                }
                if (got_snr) {
                    copy_string_safe(rec->snr, sizeof(rec->snr), snr);
                }
                copy_string_safe(rec->status, sizeof(rec->status), status[0] ? status : "unknown");
                copy_string_safe(rec->reason, sizeof(rec->reason), reason[0] ? reason : "unknown");
                rec->last_update = time(NULL);
                updated_count++;
            }
        }

        cursor = next_cursor;
    }

    if (updated_count > 0) {
        printf("[CACHE] Updated %d client records\n", updated_count);
    }
}

static void on_signal(int sig)
{
    UNREFERENCED_PARAMETER(sig);
    g_running = 0;
}

static void diagdata_handler(rbusHandle_t handle, rbusEvent_t const *event,
    rbusEventSubscription_t *subscription)
{
    rbusValue_t value = NULL;
    int len = 0;
    char const *payload = NULL;

    UNREFERENCED_PARAMETER(handle);

    if (!event || !subscription) {
        return;
    }

    /* Try lookup by subscription name first (matches existing sample app patterns) */
    value = rbusObject_GetValue(event->data, subscription->eventName);
    if (!value) {
        value = rbusObject_GetValue(event->data, event->name);
    }
    if (!value) {
        value = rbusObject_GetValue(event->data, "value");
    }
    if (!value) {
        printf("[DiagData] event=%s payload=<null value>\n", event->name ? event->name : "unknown");
        return;
    }

    payload = rbusValue_GetString(value, &len);
    if (!payload) {
        printf("[DiagData] event=%s payload=<non-string value>\n",
            event->name ? event->name : "unknown");
        return;
    }

    g_diag_events_received++;
    update_client_db_from_payload(payload, event->name);
    fflush(stdout);
}

static void client_state_handler(rbusHandle_t handle, rbusEvent_t const *event,
    rbusEventSubscription_t *subscription)
{
    rbusValue_t value = NULL;
    client_record *rec = NULL;
    bool should_publish = true;
    bool was_active = false;
    int len = 0;
    int vap = 0;
    uint8_t const *data_ptr = NULL;
    char diag_event_name[MAX_NAME] = { 0 };
    char event_type[32] = { 0 };
    char mac_str[32] = { 0 };

    UNREFERENCED_PARAMETER(handle);

    if (!event || !subscription) {
        return;
    }

    value = rbusObject_GetValue(event->data, subscription->eventName);
    if (!value) {
        value = rbusObject_GetValue(event->data, event->name);
    }
    if (!value) {
        value = rbusObject_GetValue(event->data, "value");
    }
    if (!value) {
        printf("[CLIENT] event=%s payload=<null value>\n", event->name ? event->name : "unknown");
        return;
    }

    data_ptr = rbusValue_GetBytes(value, &len);
    if (!data_ptr || len != 6) {
        printf("[CLIENT] event=%s payload=<unexpected bytes len=%d>\n", event->name ? event->name : "unknown", len);
        return;
    }

    /* Translate the RBUS event name into a simple state label */
    if (event->name && strstr(event->name, "X_RDK_deviceConnected")) {
        copy_string_safe(event_type, sizeof(event_type), "connected");
    } else if (event->name && strstr(event->name, "X_RDK_deviceDisconnected")) {
        copy_string_safe(event_type, sizeof(event_type), "disconnected");
    } else if (event->name && strstr(event->name, "X_RDK_deviceDeauthenticated")) {
        copy_string_safe(event_type, sizeof(event_type), "deauthenticated");
    } else {
        copy_string_safe(event_type, sizeof(event_type), "unknown");
    }

    printf("[CLIENT] event=%s state=%s MAC=%02x%02x%02x%02x%02x%02x\n",
        event->name ? event->name : "unknown", event_type,
        data_ptr[0], data_ptr[1], data_ptr[2], data_ptr[3], data_ptr[4], data_ptr[5]);

    snprintf(mac_str, sizeof(mac_str), "%02x%02x%02x%02x%02x%02x",
        data_ptr[0], data_ptr[1], data_ptr[2], data_ptr[3], data_ptr[4], data_ptr[5]);

    if (parse_vap_from_event_name(event->name, &vap)) {
        snprintf(diag_event_name, sizeof(diag_event_name),
            "Device.WiFi.AccessPoint.%d.X_RDK_DiagData", vap);
        rec = find_or_create_client_record(diag_event_name, mac_str);
        if (rec) {
            was_active = rec->active;

            /* Suppress repeated down-state events until the client reconnects */
            if ((strcmp(event_type, "disconnected") == 0 ||
                    strcmp(event_type, "deauthenticated") == 0) &&
                !was_active &&
                (strcmp(rec->status, "disconnected") == 0 ||
                    strcmp(rec->status, "deauthenticated") == 0)) {
                should_publish = false;
            }

            rec->active = (strcmp(event_type, "connected") == 0);

            if (should_publish) {
                    copy_string_safe(rec->status, sizeof(rec->status), event_type);
                    copy_string_safe(rec->reason, sizeof(rec->reason), event_type);
            }
            rec->last_update = time(NULL);
        }
    }

    if (should_publish) {
        /* Publish single-entry JSON array report for this state transition */
        char timestamp[MQTT_TIMESTAMP_LEN] = { 0 };
        char state_buf[MQTT_REPORT_ENTRY_MAX + 64];
        int state_len;

        if (!format_publish_timestamp(timestamp, sizeof(timestamp))) {
            printf("[MQTT] Failed to create publish timestamp\n");
            return;
        }

        state_len = snprintf(state_buf, sizeof(state_buf),
            "[{\"Time\":\"%s\"},{\"mac\":\"%s\",\"rssi\":\"%s\",\"snr\":\"%s\",\"status\":\"%s\",\"reason\":\"%s\"}]",
            timestamp,
            mac_str,
            (rec && rec->rssi[0]) ? rec->rssi : "NA",
            (rec && rec->snr[0])  ? rec->snr  : "NA",
            event_type,
            event_type);

        if (state_len > 0 && state_len < (int)sizeof(state_buf)) {
            mqtt_publish_report(state_buf, state_len);
        }
    } else {
        printf("[CLIENT] duplicate down-state suppressed for MAC=%s\n", mac_str);
    }

    fflush(stdout);
}

static bool parse_vap_list(char *arg, int *vaps, int *count)
{
    char *token = NULL;
    int idx = 0;

    if (!arg || !vaps || !count) {
        return false;
    }

    token = strtok(arg, ",");
    while (token != NULL) {
        char *end = NULL;
        long vap;

        trim_whitespace_safe(token);

        if (token[0] == '\0') {
            return false;
        }

        vap = strtol(token, &end, 10);
        if (!end || *end != '\0' || vap < 1 || vap > MAX_VAPS) {
            return false;
        }

        vaps[idx++] = (int)vap;
        if (idx >= MAX_VAPS) {
            break;
        }
        token = strtok(NULL, ",");
    }

    if (idx == 0) {
        return false;
    }

    *count = idx;
    return true;
}

static bool set_default_hotspot_vaps(int *vaps, int *count)
{
    if (!vaps || !count) {
        return false;
    }

    /* RDK standard uses hotspot VAP instances 13,14 */
    vaps[0] = 13;
    vaps[1] = 14;
    *count = 2;

    return true;
}

static void print_usage(char const *prog)
{
    printf("Usage: %s [-v vap_list] [-H [hotspot_vap_list]] [-i interval_ms]\n", prog);
    printf("  -v vap_list      comma-separated VAP list (default: 1)\n");
    printf("  -H [vap_list]    hotspot-only mode. Default hotspot VAPs: 13,14\n");
    printf("                   You can override with list, e.g. -H 13,14\n");
    printf("  -i interval_ms   subscription interval in ms (default: 5000)\n");
    printf("\nExamples:\n");
    printf("  %s\n", prog);
    printf("  %s -v 1,2,13 -i 10000\n", prog);
    printf("  %s -H\n", prog);
    printf("  %s -H 13,14 -i 5000\n", prog);
}

int main(int argc, char *argv[])
{
    int rc;
    int c;
    int interval = 5000;
    int vaps[MAX_VAPS] = { 1 };
    int vap_count = 1;
    bool hotspot_only = false;
    char component_name[64] = { 0 };
    char event_name[MAX_NAME];
    char *vap_arg_copy = NULL;
    time_t last_publish_ts;

    while ((c = getopt(argc, argv, "hv:i:H::")) != -1) {
        switch (c) {
        case 'h':
            print_usage(argv[0]);
            return 0;
        case 'v':
            vap_arg_copy = strdup(optarg);
            if (!vap_arg_copy) {
                printf("Failed to parse -v argument\n");
                return 1;
            }
            if (!parse_vap_list(vap_arg_copy, vaps, &vap_count)) {
                printf("Invalid VAP list. Example: -v 1,2,13\n");
                free(vap_arg_copy);
                return 1;
            }
            free(vap_arg_copy);
            vap_arg_copy = NULL;
            break;
        case 'i': {
            char *end_ptr = NULL;
            errno = 0;
            interval = (int)strtol(optarg, &end_ptr, 10);
            if (end_ptr == optarg || *end_ptr != '\0' || interval <= 0 || errno != 0) {
                printf("Invalid interval. Use a positive integer in milliseconds.\n");
                return 1;
            }
            break;
        }
        case 'H':
            /* Hotspot mode uses default hotspot VAPs unless overridden */
            hotspot_only = true;
            if (optarg && optarg[0] != '\0') {
                vap_arg_copy = strdup(optarg);
                if (!vap_arg_copy) {
                    printf("Failed to parse -H argument\n");
                    return 1;
                }
                if (!parse_vap_list(vap_arg_copy, vaps, &vap_count)) {
                    printf("Invalid hotspot VAP list. Example: -H 13,14\n");
                    free(vap_arg_copy);
                    return 1;
                }
                free(vap_arg_copy);
                vap_arg_copy = NULL;
            } else {
                if (!set_default_hotspot_vaps(vaps, &vap_count)) {
                    printf("Failed to set default hotspot VAP list\n");
                    return 1;
                }
            }
            break;
        default:
            print_usage(argv[0]);
            return 1;
        }
    }

    if (hotspot_only) {
        printf("Hotspot-only mode enabled\n");
    }

    snprintf(component_name, sizeof(component_name), "WiFiDiagDataSubscriber_%d", getpid());

    rc = rbus_open(&g_handle, component_name);
    if (rc != RBUS_ERROR_SUCCESS) {
        printf("rbus_open failed: %d\n", rc);
        return 1;
    }

    if (!mqtt_init()) {
        printf("[MQTT] continuing without MQTT publish\n");
    }

    int total_subs = vap_count * SUBS_PER_VAP;

    g_subs = (rbusEventSubscription_t *)calloc((size_t)total_subs, sizeof(rbusEventSubscription_t));
    if (!g_subs) {
        printf("Failed to allocate subscriptions\n");
        mqtt_cleanup();
        rbus_close(g_handle);
        return 1;
    }

    for (int i = 0; i < vap_count; i++) {
        int base = i * SUBS_PER_VAP;

        memset(event_name, 0, sizeof(event_name));
        snprintf(event_name, sizeof(event_name), "Device.WiFi.AccessPoint.%d.X_RDK_DiagData", vaps[i]);

        g_subs[base].eventName = strdup(event_name);
        g_subs[base].interval = interval;
        g_subs[base].handler = diagdata_handler;

        memset(event_name, 0, sizeof(event_name));
        snprintf(event_name, sizeof(event_name),
            "Device.WiFi.AccessPoint.%d.X_RDK_deviceConnected", vaps[i]);
        g_subs[base + 1].eventName = strdup(event_name);
        g_subs[base + 1].interval = 0;
        g_subs[base + 1].handler = client_state_handler;

        memset(event_name, 0, sizeof(event_name));
        snprintf(event_name, sizeof(event_name),
            "Device.WiFi.AccessPoint.%d.X_RDK_deviceDisconnected", vaps[i]);
        g_subs[base + 2].eventName = strdup(event_name);
        g_subs[base + 2].interval = 0;
        g_subs[base + 2].handler = client_state_handler;

        memset(event_name, 0, sizeof(event_name));
        snprintf(event_name, sizeof(event_name),
            "Device.WiFi.AccessPoint.%d.X_RDK_deviceDeauthenticated", vaps[i]);
        g_subs[base + 3].eventName = strdup(event_name);
        g_subs[base + 3].interval = 0;
        g_subs[base + 3].handler = client_state_handler;

        if (!g_subs[base].eventName || !g_subs[base + 1].eventName ||
            !g_subs[base + 2].eventName || !g_subs[base + 3].eventName) {
            printf("Failed to allocate event name\n");
            for (int j = 0; j <= base + 3; j++) {
                free((void *)g_subs[j].eventName);
            }
            free(g_subs);
            g_subs = NULL;
            mqtt_cleanup();
            rbus_close(g_handle);
            return 1;
        }
    }

    rc = rbusEvent_SubscribeEx(g_handle, g_subs, total_subs, 0);
    if (rc != RBUS_ERROR_SUCCESS) {
        printf("rbusEvent_SubscribeEx failed: %d\n", rc);
        for (int i = 0; i < total_subs; i++) {
            free((void *)g_subs[i].eventName);
        }
        free(g_subs);
        mqtt_cleanup();
        rbus_close(g_handle);
        return 1;
    }

    g_sub_count = total_subs;

    printf("Subscribed to DiagData with interval=%d ms\n", interval);
    printf("Subscribed to client state events: connected/disconnected/deauthenticated\n");
    for (int i = 0; i < g_sub_count; i++) {
        printf("  %s\n", g_subs[i].eventName);
    }
    printf("\n[NOTE] Events may be missed if clients connect during subscription startup.\n");
    printf("[NOTE] DiagData will still capture all active clients after first poll.\n");
    printf("Press Ctrl+C to exit...\n\n");

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    last_publish_ts = time(NULL);

    /* Main loop only drives the periodic MQTT publish tick */
    while (g_running) {
        time_t now = time(NULL);
        if ((now - last_publish_ts) >= MQTT_PUBLISH_PERIOD_SEC) {
            publish_client_db_snapshot();
            last_publish_ts = now;
        }
        sleep(1);
    }

    if (g_sub_count > 0) {
        rbusEvent_UnsubscribeEx(g_handle, g_subs, g_sub_count);
    }

    for (int i = 0; i < g_sub_count; i++) {
        free((void *)g_subs[i].eventName);
    }
    free(g_subs);
    g_subs = NULL;

    rbus_close(g_handle);
    g_handle = NULL;

    mqtt_cleanup();

    printf("Exited.\n");
    return 0;
}
