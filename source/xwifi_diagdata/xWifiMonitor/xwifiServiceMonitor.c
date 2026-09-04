/*
 * If not stated otherwise in this file or this component's LICENSE file
 * the following copyright and licenses apply:
 *
 * Copyright 2022 RDK Management
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include<stdio.h>
#include <stdlib.h>
#include<string.h>
#include<pthread.h>
#include<sys/inotify.h>
#include<errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdbool.h>
#include "ccsp_trace.h"
#include <syscfg/syscfg.h>
#include <sysevent/sysevent.h>
#include <sys/sysinfo.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include "secure_wrapper.h"
#include "xwifiServiceMonitor.h"

#define BUF_SIZE 256

/* VAP instance numbers used by xwifi_diagdata for each supported radio band.
 * These map to Device.WiFi.AccessPoint.<N>.* private-VAP indices and are
 * fixed by the RDKB data model convention across platforms. */
#define XWIFI_DIAGDATA_VAP_5G  "10"
#define XWIFI_DIAGDATA_VAP_6G  "21"
#define XWIFI_DIAGDATA_INTERVAL_MS "30000"

pthread_t tid;
/**
 * Execute commands and return results
 *
 * @param[in]   cmd     Command to be executed
 * @param[out]  out     Execution output
 * @param[in]   out_sz  Buffer size of the out parameter. Execution output will be clipped if the command output is
 *                      larger that out_sz.
 * @return Returns the return value of executed command.
 */
static int cmd_exec(char *cmd, char *out, size_t out_sz) 
{
    FILE        *fp;
    char        buf[BUF_SIZE];
    size_t      total_read = 0;
    fp = popen(cmd, "r");
    if (!fp) 
    {
        CcspTraceInfo(("%s - popen failed, errno = %d\n", cmd, errno));
        return errno;
    }
    memset(out, 0, out_sz);
    while (fgets(buf, BUF_SIZE, fp) != NULL) 
    {
        size_t len = strlen(buf);
        if (total_read + len >= out_sz) 
        {
            CcspTraceInfo(("Exceeded buffer size, clipping output\n"));
            break;
        }
        strncpy(out + total_read, buf, out_sz - total_read - 1);
        total_read += len;
    }
    while(out[strlen(out)-1] == '\r' || out[strlen(out)-1] == '\n') 
    {
        out[strlen(out)-1] = '\0';
    }
    return pclose(fp);
}
//Check if Xfinity Wifi is enabled
bool getXfinityWifiEnableStatus()
{
    char buf[8];
    char cmd[256];
    memset(cmd, 0, sizeof(cmd));
    memset(buf,0,sizeof(buf));
    snprintf(cmd, sizeof(cmd), "dmcli eRT getv Device.DeviceInfo.X_COMCAST_COM_xfinitywifiEnable | grep 'value:'|cut -d':' -f3| xargs");
    CcspTraceInfo(("Command - %s\n",cmd));
    if (cmd_exec(cmd, buf, sizeof(buf))) {
        CcspTraceInfo(("Command Execution failed\n"));
    } else {
        CcspTraceInfo(("Command Execution success\n"));
    }
    if(strcmp(buf,"true")==0)
        return true;
    else
        return false;
}

/*
 * Determine if this device supports a 6GHz radio by querying the number of
 * WiFi radios present and inspecting each radio's OperatingFrequencyBand.
 * This avoids hardcoding per-platform (XB7/XB8/XB10/...) logic and instead
 * relies on the data model, which correctly reflects each device's actual
 * hardware/software capability (5G-only vs 5G+6G).
 */
static bool is6GHzRadioSupported(void)
{
    char buf[16] = {0};
    char cmd[256] = {0};
    int radioCount = 0;
    int i;

    snprintf(cmd, sizeof(cmd),
        "dmcli eRT getv Device.WiFi.RadioNumberOfEntries | grep 'value:' | cut -d':' -f3 | xargs");
    if (cmd_exec(cmd, buf, sizeof(buf)) != 0 || buf[0] == '\0')
    {
        CcspTraceWarning(("%s: Failed to get RadioNumberOfEntries\n", __FUNCTION__));
        return false;
    }

    radioCount = atoi(buf);
    if (radioCount <= 0)
    {
        CcspTraceWarning(("%s: Invalid RadioNumberOfEntries value '%s'\n", __FUNCTION__, buf));
        return false;
    }

    for (i = 1; i <= radioCount; i++)
    {
        char band[16] = {0};

        memset(cmd, 0, sizeof(cmd));
        snprintf(cmd, sizeof(cmd),
            "dmcli eRT getv Device.WiFi.Radio.%d.OperatingFrequencyBand | grep 'value:' | cut -d':' -f3 | xargs",
            i);
        if (cmd_exec(cmd, band, sizeof(band)) != 0 || band[0] == '\0')
        {
            continue;
        }

        if (strstr(band, "6GHz") != NULL)
        {
            CcspTraceInfo(("%s: 6GHz radio detected at Device.WiFi.Radio.%d\n", __FUNCTION__, i));
            return true;
        }
    }

    return false;
}

/*
 * Build the VAP list ("10" or "10,21") dynamically based on the radios
 * actually present/supported on this device, instead of relying on static
 * per-platform macros.
 */
static void buildXwifiDiagDataVapList(char *vapList, size_t vapList_len)
{
    if (!vapList || vapList_len == 0)
    {
        return;
    }

    if (is6GHzRadioSupported())
    {
        snprintf(vapList, vapList_len, "%s,%s", XWIFI_DIAGDATA_VAP_5G, XWIFI_DIAGDATA_VAP_6G);
    }
    else
    {
        snprintf(vapList, vapList_len, "%s", XWIFI_DIAGDATA_VAP_5G);
    }
}

void *executeXwifiDiagDataService(void *data)
{
    pthread_detach(pthread_self());
    CcspTraceInfo(("Entering %s: \n", __FUNCTION__));
    struct sysinfo s_info;
	sysinfo(&s_info);
    while(s_info.uptime <= 300)// 300 this wait for device boot up then only monitor services will run
    {
        CcspTraceInfo(("whileloop device uptime - %d\n",__LINE__));
        sysinfo(&s_info);
        sleep(60);//60sec
    }
    CcspTraceInfo(("After device uptime - %d\n",__LINE__));
    while(1)
    {
        if (getXfinityWifiEnableStatus())
        {
            char vapList[32] = {0};

            buildXwifiDiagDataVapList(vapList, sizeof(vapList));

            CcspTraceInfo(("%s: Initializing publicVap_util. \n", __FUNCTION__));
            CcspTraceInfo(("%s: Starting xwifi_diagdata with -v %s -i %s\n",
                __FUNCTION__, vapList, XWIFI_DIAGDATA_INTERVAL_MS));
            v_secure_system("/usr/bin/xwifi_diagdata -v %s -i %s", vapList, XWIFI_DIAGDATA_INTERVAL_MS);
            break;
        }
        sleep(2);
    }
    return NULL;
}

/*****************************************************************************
monitorService_Init() is used for executeXwifiDiagDataService services configuration initialization
******************************************************************************/
int monitorService_xwifi_Init()
{
    CcspTraceInfo(("Enter into %s\n",__func__));
    int Error;
    Error = pthread_create(&tid,NULL,executeXwifiDiagDataService,NULL);
    if (Error)
    {
        CcspTraceInfo(("executeXwifiDiagDataService create error : %d\n",Error));
    }
    else
    {
        CcspTraceInfo(("executeXwifiDiagDataService thread created successfully\n"));
    }
    return 0;
}
