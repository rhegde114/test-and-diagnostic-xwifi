#!/bin/sh
#######################################################################################
# If not stated otherwise in this file or this component's Licenses.txt file the
# following copyright and licenses apply:

#  Copyright 2019 RDK Management

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

# http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#######################################################################################
UTOPIA_PATH="/etc/utopia/service.d"
TAD_PATH="/usr/ccsp/tad"
RDKLOGGER_PATH="/rdklogger"
PRIVATE_LAN="brlan0"
BR_MODE=0
CONSOLE_LOG="/rdklogs/logs/Consolelog.txt.0"

if [ -f /etc/ssl/certsel/hrot.properties ]; then
    source /etc/ssl/certsel/hrot.properties
fi

#upflowed INTCS-125.patch as part of RDKB-41505.
if [ "$MODEL_NUM" = "TG3482G" ] || [ "$MODEL_NUM" = "TG4482A" ]; then
	DCM_LOGS_TMP=/tmp/dcmscript_tmp.txt
	DCM_LOGS=/rdklogs/logs/dcmscript.log
	SECCONSOLE_LOGS=/rdklogs/logs/SecConsole.txt.0
	DCM_TMP_LINES=15
fi

SelfHeal_Support=`sysevent get SelfhelpWANConnectionDiagSupport`
HomeSecuritySupport=`sysevent get HomeSecuritySupport`
# Here LANIPv6GUASupport used to identify the region of the device. For example LANIPv6GUASupport is true for EU region devices and false for NA region devices. 
# Eth WAN failover recovery action is taken only for NA region devices.
# TODO : DHCP selfheal mechanisms used here are outdated and dhcp should be controlled from and Wanmanager and the DHCPManager.
UseLANIFIPV6=`sysevent get LANIPv6GUASupport`

DIBBLER_SERVER_CONF="/etc/dibbler/server.conf"


# Global variable to indicate if any DHCPv6 client is enabled
DHCPV6C_ENABLED=0

# Function to check if any DHCPv6 client is enabled
is_dhcpv6c_enabled() {
    local num_entries i enabled alias
    num_entries=$(dmcli eRT retv Device.DHCPv6.ClientNumberOfEntries 2>/dev/null)
    if [[ -z "$num_entries" ]] || [[ $num_entries -eq 0 ]]; then
        echo_t "no wan interface specified"
        DHCPV6C_ENABLED=0
        return
    fi
    for i in $(seq 1 "$num_entries"); do
        alias=$(dmcli eRT retv Device.DHCPv6.Client.$i.Alias 2>/dev/null)
        #We need to skip checking the status of DHCPv6 client for hotspot as it is used for hotspot clients, 
        #and we have to define here if any other clients are added in future which are not used for wan connection .
        if [ "$alias" = "HOTSPOT" ]; then
            continue
        fi
        enabled=$(dmcli eRT retv Device.DHCPv6.Client.$i.Enable 2>/dev/null)
        if [ "$enabled" = "true" ] || [ "$enabled" = "1" ]; then
            DHCPV6C_ENABLED=1
            return
        fi
    done
    DHCPV6C_ENABLED=0
}

if [ "$MODEL_NUM" = "TG3482G" ] || [ "$MODEL_NUM" = "CGA4131COM" ] || [ "$MODEL_NUM" = "CGM4140COM" ] || [ "$MODEL_NUM" = "CGM4331COM" ] || [ "$MODEL_NUM" = "TG4482A" ] || [ "$MODEL_NUM" = "VTER11QEL" ]
then
    DHCPV6_HANDLER="/usr/bin/service_dhcpv6_client"
else
    DHCPV6_HANDLER="/etc/utopia/service.d/service_dhcpv6_client.sh"
fi

# Disabling Device.DHCPv6.Client.1.Enable check for now. Will be enabled once parameter is used to Enable or Disable v4/v6 clients in the field.

#if [ -f /tmp/dhcpmgr_initialized ]; then
#   DHCPV4C_STATUS=$(dmcli eRT retv Device.DHCPv4.Client.1.Enable)
#   DHCPV6C_STATUS=$(dmcli eRT retv Device.DHCPv6.Client.1.Enable)
#else
#   DHCPV4C_STATUS=true
#   DHCPV6C_STATUS=true
#fi

    DHCPV4C_STATUS=true
    DHCPV6C_STATUS=true

Unit_Activated=$(syscfg get unit_activated)
source $TAD_PATH/corrective_action.sh
source /etc/utopia/service.d/event_handler_functions.sh
source /etc/waninfo.sh
ovs_enable=false

if [ -d "/sys/module/openvswitch/" ];then
   ovs_enable=true
fi
bridgeUtilEnable=`syscfg get bridge_util_enable`
MAPT_CONFIG=`sysevent get mapt_config_flag`

PSM_SHUTDOWN="/tmp/.forcefull_psm_shutdown"

# use SELFHEAL_TYPE to handle various code paths below (BOX_TYPE is set in device.properties)
case $BOX_TYPE in
    "XB3") SELFHEAL_TYPE="BASE";;
    "XB6") SELFHEAL_TYPE="SYSTEMD";;
    "XF3") SELFHEAL_TYPE="SYSTEMD";;
    "TCCBR") SELFHEAL_TYPE="TCCBR";;
    "pi"|"rpi"|"bpi") SELFHEAL_TYPE="BASE";;  # TBD?!
    "HUB4") SELFHEAL_TYPE="SYSTEMD";;
    "SR300") SELFHEAL_TYPE="SYSTEMD";;
    "SE501") SELFHEAL_TYPE="SYSTEMD";;
    "SR213") SELFHEAL_TYPE="SYSTEMD";;
    "WNXL11BWL") SELFHEAL_TYPE="SYSTEMD";;
    "SCER11BEL") SELFHEAL_TYPE="SYSTEMD";;
    "VNTXER5") SELFHEAL_TYPE="SYSTEMD";;
    "SCXF11BFL") SELFHEAL_TYPE="SYSTEMD";;
    "ipq") SELFHEAL_TYPE="SYSTEMD";;
    "XER2") SELFHEAL_TYPE="SYSTEMD";;
    *)
        echo_t "RDKB_SELFHEAL : ERROR: Unknown BOX_TYPE '$BOX_TYPE', using SELFHEAL_TYPE='BASE'"
        SELFHEAL_TYPE="BASE";;
esac

case $MODEL_NUM in
            "CGA4332COM") SELFHEAL_TYPE="SYSTEMD";;
            *) ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
        grePrefix="gretap0"
        brlanPrefix="brlan"
        l2sd0Prefix="l2sd0"
        #(already done by corrective_action.sh)source /etc/log_timestamp.sh

        if [ -f /etc/mount-utils/getConfigFile.sh ]; then
            . /etc/mount-utils/getConfigFile.sh
        fi

        if [ "$MODEL_NUM" = "DPC3939" ] || [ "$MODEL_NUM" = "DPC3941" ]; then
            ADVSEC_PATH="/tmp/cujo_dnld/usr/ccsp/advsec/advsec.sh"
        else
            ADVSEC_PATH="/usr/ccsp/advsec/advsec.sh"
        fi
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
        ADVSEC_PATH="/usr/ccsp/advsec/advsec.sh"
    ;;
esac

ping_failed=0
ping_success=0
SyseventdCrashed="/rdklogs/syseventd_crashed"
PARCONNHEALTH_PATH="/tmp/parconnhealth.txt"
PING_PATH="/usr/sbin"

case $SELFHEAL_TYPE in
    "BASE")
        SNMPMASTERCRASHED="/tmp/snmp_cm_crashed"
        WAN_INTERFACE=$(getWanInterfaceName)

        if [ ! -f /usr/bin/GetConfigFile ]; then
            echo "Error: GetConfigFile Not Found"
            exit
        fi
        IDLE_TIMEOUT=60
    ;;
    "TCCBR")
        WAN_INTERFACE=$(getWanInterfaceName)

        if [ ! -f /usr/bin/GetConfigFile ]; then
            echo "Error: GetConfigFile Not Found"
            exit
        fi
        IDLE_TIMEOUT=30
    ;;
    "SYSTEMD")
    ;;
esac


CCSP_ERR_NOT_CONNECT=190
CCSP_ERR_TIMEOUT=191
CCSP_ERR_NOT_EXIST=192

exec 3>&1 4>&2 >> $SELFHEALFILE 2>&1



# set thisREADYFILE for several tests below:
case $SELFHEAL_TYPE in
    "BASE")
    ;;
    "TCCBR")
        thisREADYFILE="/tmp/.brcm_wifi_ready"
    ;;
    "SYSTEMD")
        thisREADYFILE="/tmp/.qtn_ready"
        case $MODEL_NUM in
            *CGM4331COM*) thisREADYFILE="/tmp/.brcm_wifi_ready";;
            *TG4482A*) thisREADYFILE="/tmp/.puma_wifi_ready";; ## This will need to change during integration effort
            *) ;;
        esac
    ;;
esac

# set thisWAN_TYPE for several tests below:
case $SELFHEAL_TYPE in
    "BASE")
        thisWAN_TYPE="$WAN_TYPE"
    ;;
    "TCCBR")
        thisWAN_TYPE="NOT_EPON" # WAN_TYPE is undefined for TCCBR, so kludge it so that tests fail for "EPON"
    ;;
    "SYSTEMD")
        thisWAN_TYPE="$WAN_TYPE"
    ;;
esac


# set thisIS_BCI for several tests below:
# 'thisIS_BCI' is used where 'IS_BCI' was added in recent changes (c.6/2019)
# 'IS_BCI' is still used when appearing in earlier code.
# TBD: may be able to set 'thisIS_BCI=$IS_BCI' for ALL devices?
case $SELFHEAL_TYPE in
    "BASE")
        thisIS_BCI="$IS_BCI"
    ;;
    "TCCBR")
        thisIS_BCI="no"
    ;;
    "SYSTEMD")
        thisIS_BCI="no"
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
        if [ -f $ADVSEC_PATH ]; then
            source $ADVSEC_PATH
        fi
        reboot_needed_atom_ro=0
        if [ "$thisIS_BCI" != "yes" ]; then
            brlan1_firewall="/tmp/brlan1_firewall_rule_validated"
        fi
    ;;
    "TCCBR")
        reb_window=0
    ;;
    "SYSTEMD")
        WAN_INTERFACE=$(getWanInterfaceName)

        if [ -f $ADVSEC_PATH ]; then
            source $ADVSEC_PATH
        fi

        brlan1_firewall="/tmp/brlan1_firewall_rule_validated"
    ;;
esac


check_xle_dns_route()
{
    need_dns_correction=0
    cellular_manager_gw=$(sysevent get cellular_wan_v4_gw)
    if [ "$cellular_manager_gw" != "0.0.0.0" ] && [ -n "$cellular_manager_gw" ] ;then
        cellular_manager_dns1=$(sysevent get cellular_wan_v4_dns1)
        cellular_manager_dns2=$(sysevent get cellular_wan_v4_dns2)
        route_table=$(ip route show)
        dns1_missing=$(echo "$route_table" | grep $cellular_manager_dns1)
        dns2_missing=$(echo "$route_table" | grep $cellular_manager_dns2)
        if [ -z "$dns1_missing" ] || [ -z "$dns2_missing" ] ;then
            echo_t "[RDKB_SELFHEAL] : Ipv4 dns route missing"
            need_dns_correction=1
        fi
    fi

    cellular_manager_dns1=""
    cellular_manager_dns2=""
    dns1_missing=""
    dns2_missing=""

    cellular_manager_v6_gw=$(sysevent get cellular_wan_v6_gw | cut -d "/" -f 1)
    if [ "$cellular_manager_v6_gw" != "::" ] && [ -n "$cellular_manager_v6_gw" ] ;then
        cellular_manager_dns1=$(sysevent get cellular_wan_v6_dns1)
        cellular_manager_dns2=$(sysevent get cellular_wan_v6_dns2)

        routev6_table=$(ip -6 route show)
        dns1_missing=$(echo "$routev6_table" | grep $cellular_manager_dns1)
        dns2_missing=$(echo "$routev6_table" | grep $cellular_manager_dns2)
        if [ -z "$dns1_missing" ] || [ -z "$dns2_missing" ] ;then
            echo_t "[RDKB_SELFHEAL] : Ipv6 dns route missing"
            need_dns_correction=1
        fi
    fi
    if [ $need_dns_correction -eq 1 ];then
        echo_t "[RDKB_SELFHEAL] : Correcting dns route"
        sysevent set correct_dns_route
    fi

}

self_heal_meshAgent_ensure_running()
{
    if ! systemctl is-active --quiet meshAgent; then
        echo_t "[RDKB_SELFHEAL] : meshAgent is not running. Restarting service..."
        systemctl restart meshAgent
    fi
}

self_heal_meshAgent()
{
    cpu_max=20
    mesh=`pidof meshAgent`
    cpu=`top -n 1 | awk '/mesh/ {print $7}' | sed s/"%"//`
    if [ ! -z "$cpu" ] && [ "$cpu" -gt "$cpu_max" ];then
       echo_t "[RDKB_SELFHEAL] :meshAgent is consuming more CPU , restarting meshAgent CPU: $cpu"
       systemctl restart meshAgent
    fi
}

check_br403_is_created() {

    local mesh_enable bridgeUtilEnable ovs_enable=false ip_addr
    local IFACE="br403"

    mesh_enable="$(syscfg get mesh_enable 2>/dev/null)"
    bridgeUtilEnable="$(syscfg get bridge_util_enable 2>/dev/null)"

    if command -v ovs-vsctl >/dev/null 2>&1; then
        ovs_enable=true
    fi

    if [[ "$ovs_enable" != "true" && "$bridgeUtilEnable" != "true" ]] \
       || [ "$mesh_enable" = "false" ]; then
        return 0
    fi

    if [ "$ovs_enable" = "true" ]; then
        if ! ovs-vsctl br-exists "$IFACE" 2>/dev/null; then
            echo_t "[RDKB_SELFHEAL] : Interface $IFACE does not exist, creating it."
            sysevent set meshbhaul-setup 10
            return 0
        fi
    else
        if ! brctl show 2>/dev/null | awk '{print $1}' | grep -qx "$IFACE"; then
            echo_t "[RDKB_SELFHEAL] : Interface $IFACE does not exist, creating it."
            sysevent set meshbhaul-setup 10
            return 0
        fi
    fi

    echo_t "[RDKB_SELFHEAL] : Interface $IFACE present"

    ip_addr="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '{print $2}')"

    if [ -z "$ip_addr" ]; then
        echo_t "[RDKB_SELFHEAL] : Interface $IFACE does NOT have an IP address."
        sysevent set meshbhaul-setup 10
    fi
}

self_heal_meshAgent_hung() {
    dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.Mesh.Enable > /dev/null &
    local cmd_pid=$!
    sleep 5
    process_info=$(ps | awk -v pid="$cmd_pid" '$1 == pid')
    if [ -n "$process_info" ];then
       if kill -0 $cmd_pid 2>/dev/null;then
          kill $cmd_pid
          if [ -f /tmp/meshagent_restart ];then
             echo_t "[RDKB_SELFHEAL] :meshAgent is hung, defer restart"
             systemctl restart meshAgent
             rm /tmp/meshagent_restart
          else
             echo_t "[RDKB_SELFHEAL] :meshAgent is hung, wait for one more iteration"
             touch /tmp/meshagent_restart
          fi
       else
          if [ -f /tmp/meshagent_restart ];then
             rm /tmp/meshagent_restart
          fi
       fi
    else
        if [ -f /tmp/meshagent_restart ];then
           rm /tmp/meshagent_restart
        fi
    fi
}

# This is a workaround to be out of the finger pointing state of telemetry2_0 being in between generic KP monitoring and uncontrolled profile assignments from cloud
# Purpose of this selfheal is to restart telemetry2_0 if it is :
#   1] Consuming more memory than the threshold
#   2] Stops reporting due to issues external to telemetry2_0 causing it to go to hung state
self_heal_t2() {

    restartNeeded=0

    # Floor limit on telemetry2_0 memory usage
    t2MemMax=30000
    # using busybox as different platforms are behaving differently with top command using -mbn1 to get the rss data
    # using sort command and head 1 to get the highest value; there is a chance that multiple pids {
    t2MemUsed=`busybox top -mbn 1 | grep "/usr/bin/telemetry2_0" | grep -v "grep"| awk '/telemetry2_0/ {print $4}' | sort -nr | head -n1`
    t2MemUsedUnits=${t2MemUsed: -1}
    #t2MemUsed=${t2MemUsed%?}
    # Remove the last unit only if it is a char m,M,g,G.
    t2MemUsed=${t2MemUsed%[a-zA-Z]}
    if [ "$t2MemUsedUnits" == "g" ] || [ "$t2MemUsedUnits" == "G" ]; then
        t2MemUsed=$((t2MemUsed*1024))
        t2MemUsedUnits="m"
    fi

    if [ "$t2MemUsedUnits" == "m" ] || [ "$t2MemUsedUnits" == "M" ]; then
        t2MemUsed=$((t2MemUsed*1024))
        t2MemUsedUnits="k"
    fi

    if [ "$t2MemUsed" -gt "$t2MemMax" ]; then
        echo_t "[RDKB_SELFHEAL] : telemetry2_0 is consuming $t2MemUsed$t2MemUsedUnits  memory which is greater than floor limit of $t2MemMax . restarting telemetry2_0 ..."
        restartNeeded=1
    fi

    # Check if telemetry2_0 is hung
    t2Pid=`pidof telemetry2_0`
    if [ ! -z "$t2Pid" ]; then
        # Check if telemetry2_0 is hung - Below logic is based on the assumption that operations continues with 15 minute interval legacy profile  
        # Compare the last updated time of telemetry2_0 log file with current time
        # If the difference is more than 15 minutes, then telemetry2_0 could be potentially in hung state
        t2LogLastUpdated=`date +%s -r /rdklogs/logs/telemetry2_0.txt.0`
        currentTime=`date +%s`
        timeDiff=$((currentTime-t2LogLastUpdated))
        MAX_TIME_DIFF=1080 # 18 minutes
        if [ "$timeDiff" -gt "$MAX_TIME_DIFF" ]; then
            echo_t "[RDKB_SELFHEAL] : telemetry2_0 is not reporting. Set restart flag for telemetry2_0."
            restartNeeded=1
        fi
    fi

    # Check for rbus communication failure
    ERROR_STRING="rbus_set Failed for \[Telemetry.ReportProfiles.EventMarker\]"
    telemetry2_0_client "TEST_RT_CONNECTION" "1" > /tmp/t2_test_broker_health 2>&1
    if [ -f /tmp/t2_test_broker_health ]; then
        if [ `grep -c "$ERROR_STRING" /tmp/t2_test_broker_health` -gt 0 ]; then
            echo_t "[RDKB_SELFHEAL] : telemetry2_0 is hung at rbus queries. Set restart flag for telemetry2_0."
            restartNeeded=1
        fi
        rm -f /tmp/t2_test_broker_health
    fi

    if [ "$restartNeeded" -eq 1 ]; then
        echo_t "[RDKB_SELFHEAL] : Restarting telemetry2_0" 
        echo_t "[RDKB_SELFHEAL] : Restarting telemetry2_0. Lookup in selfheal for restart reason !!!" >> /rdklogs/logs/telemetry2_0.txt.0
        kill -9 `pidof telemetry2_0`
        if [ -f /lib/rdk/dcm.service ]; then 
            /lib/rdk/dcm.service
        fi
    fi

}

self_heal_dual_cron()
{
    CRONTAB_DIR="/var/spool/cron/crontabs/"
    CRON_FILE_BK="/tmp/cron_tab$$.txt"

    #This is to enable logging if duplicate/dual cron jobs are detected in crontab.
    crontab_count=$(crontab -l -c $CRONTAB_DIR | wc -l)
    crontab_count_unique=$(crontab -l -c $CRONTAB_DIR | awk '!visited[$0]++' | wc -l)
    if [[ $crontab_count -ne $crontab_count_unique ]]
    then
        echo_t "[RDKB_SELFHEAL] : Duplicate crontab detected. Removing Duplicates."
        t2CountNotify "SYS_ERROR_Duplicate_crontab"
        crontab -l -c $CRONTAB_DIR | awk '!visited[$0]++' > $CRON_FILE_BK
        crontab $CRON_FILE_BK -c $CRONTAB_DIR
        rm -rf $CRON_FILE_BK
    fi
}

self_heal_sedaemon()
{
    if [ "$hrottype" != "pkcs11" ] && [ -f /tmp/started_ssad ] && ( [ "$kdftype" = "RSA" ] || [ "$kdftype" = "ECC" ] ); then
         accessmgr=`pidof accessManager`

         if [ "$kdftype" = "ECC" ]; then
             ssadaemon=`pidof rdkssaecckdf`
             daemon_service="rdkssaeccdaemon.service"
             daemon_name="rdkssaecckdf"
         else
             ssadaemon=`pidof se05xd`
             daemon_service="startse05xd.service"
             daemon_name="se05xd"
         fi

         if [[ -z "$ssadaemon" ]] || [[ -z "$accessmgr" ]]; then
               echo_t "[RDKB_SELFHEAL] : Restarting accessmanager and $daemon_name"
               t2CountNotify "SYS_SH_SERestart"
               systemctl stop $daemon_service
               systemctl stop accessmanager.service
               systemctl start accessmanager.service
               systemctl start $daemon_service
         fi
    fi
}

xle_device_mode=0
if [ "$BOX_TYPE" = "WNXL11BWL" ]; then

    lte_down=$(sysevent get LTE_DOWN)
    if [ "$lte_down" = "1" ]; then
        echo_t "[RDKB_SELFHEAL] : Rebooting device due to LTE connectivity down"
        rebootNeeded RM LTE_DOWN LTE_DOWN 1
    fi
    # checking device mode
    xle_device_mode=`syscfg get Device_Mode`
    if [ "$xle_device_mode" -eq "1" ]; then
        RESOLV_CONF="/tmp/lte_resolv.conf"
        echo_t "[RDKB_SELFHEAL] : Device is in extender mode"
    else
        RESOLV_CONF="/etc/resolv.conf"
        echo_t "[RDKB_SELFHEAL] : Device is in router mode"
    fi
    checkMaintenanceWindow
        IsAlreadyCellularCountResetted=`sysevent get isAlreadyCellularCountResetted`
        if [ $reb_window -eq 1 ]; then
             if [ $IsAlreadyCellularCountResetted -eq 0 ]; then
                  echo_t "[RDKB_SELFHEAL] : Resetting cellular_restart_count within maintenance window"
                  sysevent set cellular_restart_count 0
                  sysevent set isAlreadyCellularCountResetted 1
             fi
        else
             if [ $IsAlreadyCellularCountResetted -eq 1 ]; then
                  echo_t "[RDKB_SELFHEAL] : Maintenance window closed. isAlreadyCellularCountResetted set to 0"
                  sysevent set isAlreadyCellularCountResetted 0
             fi
        fi
    if [ ! -s $RESOLV_CONF ] || [ -z "$(cat ${RESOLV_CONF})" ] ; then
        echo "resolv.conf is Empty, updating it"
        cat /dev/null > $RESOLV_CONF
        sysevent set correct_resolve_conf
        echo " ==== df -h ==== "
        df -h
        echo "===== free ===="
        free
        echo "===== ls -al /tmp ====="
        ls -al /tmp/
    fi
  /usr/bin/xle_selfheal $xle_device_mode &

  check_xle_dns_route
fi
if [ "$xle_device_mode" = "0" ]; then
    #Find the DHCPv6 client type 
    ti_dhcpv6_type="$(busybox pidof ti_dhcp6c)"
    dibbler_client_type="$(busybox pidof dibbler-client)"
    if [ "$ti_dhcpv6_type" = "" ] && [ ! -z "$dibbler_client_type" ];then
        DHCPv6_TYPE="dibbler-client"
    elif [ ! -z "$ti_dhcpv6_type" ] && [ "$dibbler_client_type" = "" ];then
        DHCPv6_TYPE="ti_dhcp6c"
    else
        DHCPv6_TYPE=""
    fi
    echo_t "DHCPv6_Client_type is $DHCPv6_TYPE"
fi
#function to restart Dhcpv6_Client
Dhcpv6_Client_restart ()
{
	if [ "$1" = "" ];then
		echo_t "DHCPv6 Client not running"
		return 
	fi
	if [ "$DHCPcMonitoring" == "false" ];then
		echo_t "DHCP Monitoring done by wanmanager"
		return 
	fi
	process_restart_need=0
	if [ "$2" = "restart_for_dibbler-server" ];then
        	PAM_UP="$(busybox pidof CcspPandMSsp)"
		if [ "$PAM_UP" != "" ];then
                	echo_t "PAM pid $PAM_UP & $1 pid $dibbler_client_type $ti_dhcpv6_type"
                        echo_t "RDKB_PROCESS_CRASHED : Restarting $1 to reconfigure server.conf"
			process_restart_need=1
		fi
	fi
	if ( [ "$process_restart_need" = "1" ] || [ "$2" = "Idle" ] ) && [ $DHCPV6C_STATUS != "false" ];then
		sysevent set dibbler_server_conf-status ""
		if [ "$1" = "dibbler-client" ];then
			dibbler-client stop
            sleep 2
            dibbler-client start
            sleep 5
		elif [ "$1" = "ti_dhcp6c" ];then
            if [ -f /tmp/dhcpmgr_initialized ]; then
                sysevent set dhcpv6_client-stop
            else
                $DHCPV6_HANDLER dhcpv6_client_service_disable
            fi
            sleep 2
            if [ -f /tmp/dhcpmgr_initialized ]; then
                sysevent set dhcpv6_client-start
            else
                $DHCPV6_HANDLER dhcpv6_client_service_enable
            fi
            sleep 5
		fi
		wait_till_state "dibbler_server_conf" "ready"
		touch /tmp/dhcpv6-client_restarted
	fi
	if [ ! -f "$DIBBLER_SERVER_CONF" ];then
		return 2
	elif [ ! -s  "$DIBBLER_SERVER_CONF" ];then
		return 1
        elif [ -z "$(busybox pidof dibbler-server)" ];then
        	dibbler-server stop
            sleep 2
            dibbler-server start
	fi
}

rebootDeviceNeeded=0

LIGHTTPD_CONF="/var/lighttpd.conf"

case $SELFHEAL_TYPE in
    "BASE")
        ###########################################
        if [ "$BOX_TYPE" = "XB3" ]; then
            wifi_check=$(dmcli eRT getv Device.WiFi.SSID.1.Enable)
            wifi_timeout=$(echo "$wifi_check" | grep "$CCSP_ERR_TIMEOUT")
            wifi_not_exist=$(echo "$wifi_check" | grep "$CCSP_ERR_NOT_EXIST")
            WIFI_QUERY_ERROR=0
            if [ "$wifi_timeout" != "" ] || [ "$wifi_not_exist" != "" ]; then
                echo_t "[RDKB_SELFHEAL] : Wifi query timeout"
                t2CountNotify "WIFI_ERROR_Wifi_query_timeout"
                echo_t "WIFI_QUERY : $wifi_check"
                WIFI_QUERY_ERROR=1
            fi

            SSH_ATOM_TEST=$(GetConfigFile /tmp/elxrretyt.swr stdout | ssh -I $IDLE_TIMEOUT -i /dev/stdin root@$ATOM_IP exit 2>&1)
            echo_t "SSH_ATOM_TEST : $SSH_ATOM_TEST"
            SSH_ERROR=`echo $SSH_ATOM_TEST | grep "Remote closed the connection"`
            SSH_TIMEOUT=`echo $SSH_ATOM_TEST | grep "Idle timeout"`
            ATM_HANG_ERROR=0
            # Do not remove $PEER_COMM_ID. reduces future decryptions
            if [ "$SSH_ERROR" != "" ] || [ "$SSH_TIMEOUT" != "" ]; then
                echo_t "[RDKB_SELFHEAL] : ssh to atom failed"
                ATM_HANG_ERROR=1
            fi

            if [ "$WIFI_QUERY_ERROR" = "1" ] && [ "$ATM_HANG_ERROR" = "1" ]; then
                atom_hang_count=$(sysevent get atom_hang_count)
                echo_t "[RDKB_SELFHEAL] : Atom is not responding. Count $atom_hang_count"
                if [ $atom_hang_count -ge 2 ]; then
                    CheckRebootCretiriaForAtomHang
                    atom_hang_reboot_count=$(syscfg get todays_atom_reboot_count)
                    if [ $atom_hang_reboot_count -eq 0 ]; then
                        echo_t "[RDKB_PLATFORM_ERROR] : Atom is not responding. Rebooting box.."
                        reason="ATOM_HANG"
                        rebootCount=1
                        #setRebootreason $reason $rebootCount
                        rebootNeeded $reason "" $reason $rebootCount
                    else
                        echo_t "[RDKB_SELFHEAL] : Reboot allowed for only one time per day. It will reboot in next 24hrs."
                    fi
                else
                    atom_hang_count=$((atom_hang_count + 1))
                    sysevent set atom_hang_count $atom_hang_count
                fi
            else
                sysevent set atom_hang_count 0
            fi

            ### SNMPv3 master agent self-heal ####
            if [ -f "/etc/SNMP_PA_ENABLE" ]; then
                SNMPv3_PID=$(busybox pidof snmpd)
                if [ "$SNMPv3_PID" = "" ] && [ "$ENABLE_SNMPv3" = "true" ]; then
                    # Restart disconnected master and agent
                    v3AgentPid=$(ps ww | grep -i "snmp_subagent" | grep -v "grep" | grep -i "cm_snmp_ma_2"  | awk '{print $1}')
                    if [ "$v3AgentPid" != "" ]; then
                        kill -9 "$v3AgentPid"
                    fi
                    pidOfListener=$(ps ww | grep -i "inotify" | grep 'run_snmpv3_agent.sh' | awk '{print $1}')
                    if [ "$pidOfListener" != "" ]; then
                        kill -9 "$pidOfListener"
                    fi
                    if [ -f /tmp/snmpd.conf ]; then
                        rm -f /tmp/snmpd.conf
                    fi
                    if [ -f /lib/rdk/run_snmpv3_master.sh ]; then
                        sh /lib/rdk/run_snmpv3_master.sh &
                    fi
                else
                    ### SNMPv3 sub agent self-heal ####
                    v3AgentPid=$(ps ww | grep -i "snmp_subagent" | grep -v "grep" | grep -i "cm_snmp_ma_2"  | awk '{print $1}')
                    if [ "$v3AgentPid" = "" ] && [ "$ENABLE_SNMPv3" = "true" ]; then
                        # Restart failed sub agent
                        if [ -f /lib/rdk/run_snmpv3_agent.sh ]; then
                            sh /lib/rdk/run_snmpv3_agent.sh &
                        fi
                    fi
                fi
            fi

        fi
        ###########################################

        if [ "$MULTI_CORE" = "yes" ]; then
            if [ "$CORE_TYPE" = "arm" ]; then
                # Checking logbackup PID
                LOGBACKUP_PID=$(busybox pidof logbackup)
                if [ "$LOGBACKUP_PID" = "" ]; then
                    echo_t "RDKB_PROCESS_CRASHED : logbackup process is not running, need restart"
                    /usr/bin/logbackup &
                fi
            fi
            if [ "$MODEL_NUM" = "DPC3939B" ] || [ "$MODEL_NUM" = "DPC3941B" ]; then
              # BWGRDK1271
              if [ -f $PING_PATH/ping_peer ]; then
                  WAN_STATUS=$(sysevent get wan-status)
                  if [ "$WAN_STATUS" = "started" ]; then
                      ## Check Peer ip is accessible
                      loop=1
                      ping_peer_rbt_thresh=$(syscfg get ping_peer_reboot_threshold)
                      if [ -z "$ping_peer_rbt_thresh" ]; then
                          echo "RDKB_SELFHEAL : syscfg ping_peer_reboot_threshold unavail. Set older value 3" >> $CONSOLE_LOG
                          ping_peer_rbt_thresh=3
                      fi
                      while [ "$loop" -le $ping_peer_rbt_thresh ]
                        do
                          PING_RES=$(ping_peer)
                          CHECK_PING_RES=$(echo $PING_RES | grep "packet loss" | cut -d"," -f3 | cut -d"%" -f1)
                          if [ "$CHECK_PING_RES" != "" ]
                          then
                              if [ "$CHECK_PING_RES" -ne 100 ]
                              then
                                  ping_success=1
                                  echo_t "RDKB_SELFHEAL : Ping to Peer IP is success"
                                  timestamp=$(date '+%d/%m/%Y %T')
                                  echo "$timestamp : RDKB_SELFHEAL : Ping to Peer IP is success" >> $CONSOLE_LOG
                                  break
                              else
                                  echo_t "[RDKB_PLATFORM_ERROR] : ATOM interface is not reachable"
                                  timestamp=$(date '+%d/%m/%Y %T')
                                  echo "$timestamp : [RDKB_PLATFORM_ERROR] : ATOM interface is not reachable" >> $CONSOLE_LOG
                                  ping_failed=1
                              fi
                          else
                              if [ "$DEVICE_MODEL" = "TCHXB3" ]; then
                                  check_if_l2sd0_500_up=$(ifconfig l2sd0.500 | grep "UP" )
                                  check_if_l2sd0_500_ip=$(ifconfig l2sd0.500 | grep "inet" )
                                  if [ "$check_if_l2sd0_500_up" = "" ] || [ "$check_if_l2sd0_500_ip" = "" ]
                                  then
                                      echo_t "[RDKB_PLATFORM_ERROR] : l2sd0.500 is not up, setting to recreate interface"
                                      rpc_ifconfig l2sd0.500 >/dev/null 2>&1
                                      sleep 3
                                  fi
                                  PING_RES=$(ping_peer)
                                  CHECK_PING_RES=$(echo "$PING_RES" | grep "packet loss" | cut -d"," -f3 | cut -d"%" -f1)
                                  if [ "$CHECK_PING_RES" != "" ]; then
                                      if [ "$CHECK_PING_RES" -ne 100 ]; then
                                          echo_t "[RDKB_PLATFORM_ERROR] : l2sd0.500 is up,Ping to Peer IP is success"
                                          break
                                      fi
                                  fi
                              fi
                              ping_failed=1
                          fi
                          if [ "$ping_failed" -eq 1 ] && [ "$loop" -lt $ping_peer_rbt_thresh ]; then
                              echo_t "RDKB_SELFHEAL : Ping to Peer IP failed in iteration $loop"
                              t2CountNotify "SYS_SH_pingPeerIP_Failed"
                              echo_t "RDKB_SELFHEAL : Ping command output is $PING_RES"
                              echo "RDKB_SELFHEAL : Ping to Peer IP failed in iteration $loop" >> $CONSOLE_LOG
                          else
                              cli docsis/cmstatus | grep -i "The CM status is OPERATIONAL" >/dev/null 2>&1
                              if [ $? -eq 0 ]; then
                                  echo_t "RDKB_SELFHEAL : Ping to Peer IP failed after iteration $loop also ,rebooting the device"
                                  echo "RDKB_SELFHEAL : Ping to Peer IP failed after max retry. CM OPERATIONAL. Rebooting device" >> $CONSOLE_LOG
                                  t2CountNotify "SYS_SH_pingPeerIP_Failed"
                                  echo_t "RDKB_SELFHEAL : Ping command output is $PING_RES"
                                  echo_t "RDKB_REBOOT : Peer is not up ,Rebooting device "
                                  #echo_t " RDKB_SELFHEAL : Setting Last reboot reason as Peer_down"
                                  reason="Peer_down"
                                  rebootCount=1
                                  #setRebootreason $reason $rebootCount
                                  rebootNeeded RM "" $reason $rebootCount
                              else
                                  echo_t "RDKB_SELFHEAL : Ping to Peer IP failed after iteration $loop. Skip reboot as CM is not OPERATIONAL"
                                  echo "RDKB_SELFHEAL : Ping to Peer IP failed after max retry. CM NOT OPERATIONAL. Skip Reboot" >> $CONSOLE_LOG
                                  cli docsis/cmstatus
                                  echo_t "RDKB_SELFHEAL : Wan Status - $(sysevent get wan-status)"
                                  break
                              fi
                          fi
                          loop=$((loop+1))
                          sleep 5
                        done
                  else
                      echo_t "RDKB_SELFHEAL : wan-status is $WAN_STATUS , Peer_down check bypassed"
                      timestamp=$(date '+%d/%m/%Y %T')
                      echo "$timestamp : RDKB_SELFHEAL : wan-status is $WAN_STATUS , Peer_down check bypassed" >> $CONSOLE_LOG
                  fi
              else
                  echo_t "RDKB_SELFHEAL : ping_peer command not found"
              fi
            else
              if [ -f $PING_PATH/ping_peer ]; then
                  SYSEVENTD_PID=$(busybox pidof syseventd)
                  if [ "$SYSEVENTD_PID" != "" ]; then
                      ## Check Peer ip is accessible
                      loop=1
                      while [ $loop -le 3 ]
                        do
                          WAN_STATUS=$(sysevent get wan-status)
                          echo_t "RDKB_SELFHEAL : wan-status is $WAN_STATUS"
                          if [ $WAN_STATUS != "started" ]; then
                             echo_t "RDKB_SELFHEAL : wan-status is $WAN_STATUS, Peer_down check bypassed"
                             break
                          fi
                          PING_RES=$(ping_peer)
                          CHECK_PING_RES=$(echo "$PING_RES" | grep "packet loss" | cut -d"," -f3 | cut -d"%" -f1)
                          if [ "$CHECK_PING_RES" != "" ]; then
                              if [ $CHECK_PING_RES -ne 100 ]; then
                                  ping_success=1
                                  echo_t "RDKB_SELFHEAL : Ping to Peer IP is success"
                                  break
                              else
                                  echo_t "[RDKB_PLATFORM_ERROR] : ATOM interface is not reachable"
                                  ping_failed=1
                              fi
                          else
                              if [ "$DEVICE_MODEL" = "TCHXB3" ]; then
                                  check_if_l2sd0_500_up=$(ifconfig l2sd0.500 | grep "UP" )
                                  check_if_l2sd0_500_ip=$(ifconfig l2sd0.500 | grep "inet" )
                                  if [ "$check_if_l2sd0_500_up" = "" ] || [ "$check_if_l2sd0_500_ip" = "" ]; then
                                      echo_t "[RDKB_PLATFORM_ERROR] : l2sd0.500 is not up, setting to recreate interface"
                                      rpc_ifconfig l2sd0.500 >/dev/null 2>&1
                                      sleep 3
                                  fi
                                  PING_RES=$(ping_peer)
                                  CHECK_PING_RES=$(echo "$PING_RES" | grep "packet loss" | cut -d"," -f3 | cut -d"%" -f1)
                                  if [ "$CHECK_PING_RES" != "" ]; then
                                      if [ $CHECK_PING_RES -ne 100 ]; then
                                          echo_t "[RDKB_PLATFORM_ERROR] : l2sd0.500 is up,Ping to Peer IP is success"
                                          break
                                      fi
                                  fi
                              fi
                              ping_failed=1
                          fi

                          if [ $ping_failed -eq 1 ] && [ $loop -lt 3 ]; then
                              echo_t "RDKB_SELFHEAL : Ping to Peer IP failed in iteration $loop"
                              t2CountNotify "SYS_SH_pingPeerIP_Failed"
                              echo_t "RDKB_SELFHEAL : Ping command output is $PING_RES"
                          else
                              echo_t "RDKB_SELFHEAL : Ping to Peer IP failed after iteration $loop also ,rebooting the device"
                              t2CountNotify "SYS_SH_pingPeerIP_Failed"
                              echo_t "RDKB_SELFHEAL : Ping command output is $PING_RES"
                              echo_t "RDKB_REBOOT : Peer is not up ,Rebooting device "

                              if [ "$BOX_TYPE" = "XB3" ]; then
                                 if [ -f /usr/bin/rpcclient ] && [ "$ATOM_ARPING_IP" != "" ];then
                                 echo_t "Ping to peer failed check, whether ATOM is good through RPC"
                                    RPC_RES=`rpcclient $ATOM_ARPING_IP pwd`
                                    RPC_OK=`echo $RPC_RES | grep "RPC CONNECTED"`
                                    if [ "$RPC_OK" != "" ]; then
                                       echo_t "RPC Communication with ATOM is OK"
                                       break
                                    else
                                       echo_t "RPC Communication with ATOM have an issue"
                                    fi
                                 else
                                    echo_t "ATOM_ARPING_IP is NULL , not checking communication using rpcclient"
                                 fi
                              fi
                              #echo_t " RDKB_SELFHEAL : Setting Last reboot reason as Peer_down"
                              reason="Peer_down"
                              rebootCount=1
                              #setRebootreason $reason $rebootCount
                              rebootNeeded RM "" $reason $rebootCount

                          fi
                          loop=$((loop+1))
                          sleep 5
                        done
                  else
                      echo_t "RDKB_SELFHEAL : syseventd crashed , Peer_down check bypassed"
                  fi
              else
                  echo_t "RDKB_SELFHEAL : ping_peer command not found"
              fi
            fi

            if [ -f $PING_PATH/arping_peer ]; then
                $PING_PATH/arping_peer
            else
                echo_t "RDKB_SELFHEAL : arping_peer command not found"
            fi
        else
            echo_t "RDKB_SELFHEAL : MULTI_CORE is not defined as yes. Define it as yes if it's a multi core device."
        fi
        ########################################
        if [ "$BOX_TYPE" = "XB3" ]; then
            atomOnlyReboot=$(dmesg -n 8 && dmesg | grep -i "Atom only")
            if [ "x$atomOnlyReboot" = "x" ]; then
                crTestop=$(dmcli eRT getv com.cisco.spvtg.ccsp.CR.Name)
                isCRAlive=$(echo "$crTestop" | grep "Can't find destination compo")
                isCRHung=$(echo "$crTestop" | grep "$CCSP_ERR_TIMEOUT")

                if [ "$isCRAlive" != "" ]; then
                    # Retest by querying some other parameter
                    crReTestop=$(dmcli eRT getv Device.X_CISCO_COM_DeviceControl.DeviceMode)
                    isCRAlive=$(echo "$crReTestop" | grep "Can't find destination compo")
                    RBUS_STATUS=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.RBUS.Enable | grep value | awk '{print $NF}'`
                    if [ "$isCRAlive" != "" ] || [ "$RBUS_STATUS" == "true" ]; then
                        echo_t "RDKB_PROCESS_CRASHED : CR_process is not running, need to reboot the unit"
                        vendor=$(getVendorName)
                        modelName=$(getModelName)
                        CMMac=$(getCMMac)
                        timestamp=$(getDate)
                        #echo "Setting Last reboot reason"
                        reason="CR_crash"
                        rebootCount=1
                        #setRebootreason $reason $rebootCount
                        echo_t "SET succeeded"
                        echo_t "RDKB_SELFHEAL : <$level>CABLEMODEM[$vendor]:<99000007><$timestamp><$CMMac><$modelName> RM CcspCrSsp process died,need reboot"
                        touch $HAVECRASH
                        rebootNeeded RM "CR" $reason $rebootCount
                    fi
                fi

                if [ "$isCRHung" != "" ]; then
                    # Retest by querying some other parameter
                    crReTestop=$(dmcli eRT getv Device.X_CISCO_COM_DeviceControl.DeviceMode)
                    isCRHung=$(echo "$crReTestop" | grep "$CCSP_ERR_TIMEOUT")
                    if [ "$isCRHung" != "" ]; then
                        echo_t "RDKB_PROCESS_CRASHED : CR_process is not responding, need to reboot the unit"
                        vendor=$(getVendorName)
                        modelName=$(getModelName)
                        CMMac=$(getCMMac)
                        timestamp=$(getDate)
                        #echo "Setting Last reboot reason"
                        reason="CR_hang"
                        rebootCount=1
                        #setRebootreason $reason $rebootCount
                        echo_t "SET succeeded"
                        echo_t "RDKB_SELFHEAL : <$level>CABLEMODEM[$vendor]:<99000007><$timestamp><$CMMac><$modelName> RM CcspCrSsp process not responding, need reboot"
                        touch $HAVECRASH
                        rebootNeeded RM "CR" $reason $rebootCount
                    fi
                fi

            else
                echo_t "[RDKB_SELFHEAL] : Atom only reboot is triggered"
            fi
        elif [ "$WAN_TYPE" = "EPON" ]; then
            CR_PID=$(busybox pidof CcspCrSsp)
            if [ "$CR_PID" = "" ]; then
                echo_t "RDKB_PROCESS_CRASHED : CR_process is not running, need to reboot the unit"
                vendor=$(getVendorName)
                modelName=$(getModelName)
                CMMac=$(getCMMac)
                timestamp=$(getDate)
                #echo "Setting Last reboot reason"
                reason="CR_crash"
                rebootCount=1
                #setRebootreason $reason $rebootCount
                echo_t "SET succeeded"
                echo_t "RDKB_SELFHEAL : <$level>CABLEMODEM[$vendor]:<99000007><$timestamp><$CMMac><$modelName> RM CcspCrSsp process died,need reboot"
                touch $HAVECRASH
                rebootNeeded RM "CR" $reason $rebootCount
            fi
        fi




        ###########################################
    ;;
    "SYSTEMD"|"TCCBR")
        if [ "$MODEL_NUM" = "CGM4140COM" ] || [ "$MODEL_NUM" = "CGM4331COM" ] || [ "$MODEL_NUM" = "CGM4981COM" ] || [ "$MODEL_NUM" = "CGM601TCOM" ] || [ "$MODEL_NUM" = "CWA438TCOM" ] || [ "$MODEL_NUM" = "SG417DBCT" ] || [ "$BOX_TYPE" = "TCCBR" ]; then
            Check_If_Erouter_Exists=$(ifconfig -a | grep "$WAN_INTERFACE")
            ifconfig $WAN_INTERFACE > /dev/null
            wan_exists=$?
            if [ "$Check_If_Erouter_Exists" = "" ] && [ $wan_exists -ne 0 ]; then
                echo_t "RDKB_REBOOT : Erouter0 interface is not up ,Rebooting device"
                echo_t "Setting Last reboot reason Erouter_Down"
                t2CountNotify "SYS_ERROR_ErouterDown_reboot"
                reason="Erouter_Down"
                rebootCount=1
                rebootNeeded RM "" $reason $rebootCount
            fi

        fi
	
        if [ 0 = $(syscfg get bridge_mode) ];then

            if [ "$MODEL_NUM" = "TG3482G" ] || [ "$MODEL_NUM" = "TG4482A" ] || [ "$MODEL_NUM" = "CGM4140COM" ] || [ "$MODEL_NUM" = "CGM4331COM" ]; then
              HOME_LAN_ISOLATION=`psmcli get dmsb.l2net.HomeNetworkIsolation`
              if [ "$HOME_LAN_ISOLATION" = "0" ];then
                  #ARRISXB6-9443 temp fix. Need to generalize and improve.
                      if [ "x$ovs_enable" = "xtrue" ];then
                          ovs-vsctl list-ifaces brlan0 |grep "moca0" >> /dev/null
                      else
                          brctl show brlan0 | grep "moca0" >> /dev/null
                      fi
                      if [ $? -ne 0 ] ; then
                          echo_t "Moca is not part of brlan0.. adding it"
                          psm_check="`psmcli get dmsb.l2net.1.Members.Moca`"
                          if [ "x$psm_check" = "x" ];then 
                              psmcli set dmsb.l2net.1.Members.Moca nmoca0
                          fi
                          t2CountNotify "SYS_SH_MOCA_add_brlan0"
                          sysevent set multinet-syncMembers 1
                      fi

              else
                      if [ "x$ovs_enable" = "xtrue" ];then
                          ovs-vsctl list-ifaces brlan10 |grep "moca0" >> /dev/null
                      else
                          brctl show brlan10 | grep "moca0" >> /dev/null
                      fi
                      if [ $? -ne 0 ] ; then
                          echo_t "Moca is not part of brlan10.. adding it"
                          #t2CountNotify "SYS_SH_MOCA_add_brlan10"
                          sysevent set multinet-syncMembers 9
                      fi
              fi
        fi
	fi
    ;;
esac

BR_MODE=0
bridgeMode=$(dmcli eRT getv Device.X_CISCO_COM_DeviceControl.LanManagementEntry.1.LanMode)
# RDKB-6895
bridgeSucceed=$(echo "$bridgeMode" | grep "Execution succeed")
if [ "$bridgeSucceed" != "" ]; then
	isBridging=$(echo "$bridgeMode" | grep "router")
        if [ "$isBridging" = "" ]; then
        	BR_MODE=1
                echo_t "[RDKB_SELFHEAL] : Device in bridge mode"
                if [ "$MODEL_NUM" = "CGA4332COM" ] || [ "$MODEL_NUM" = "CGA4131COM" ]; then
        		Bridge_Mode_Type=$(echo "$bridgeMode" | grep -oE "(full-bridge-static|bridge-static)")
        		if [ "$Bridge_Mode_Type" = "full-bridge-static" ]; then
            			echo_t "[RDKB_SELFHEAL] : Device in Basic Bridge mode"
        		elif [ "$Bridge_Mode_Type" = "bridge-static" ]; then
            			echo_t "[RDKB_SELFHEAL] : Device in Advanced Bridge mode"
        		fi
		fi
        fi
else
    echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking bridge mode."
    t2CountNotify "SYS_ERROR_DmCli_Bridge_mode_error"
    echo_t "LanMode dmcli called failed with error $bridgeMode"
    isBridging=$(syscfg get bridge_mode)
    if [ "$isBridging" != "0" ]; then
        BR_MODE=1
        echo_t "[RDKB_SELFHEAL] : Device in bridge mode"
        if [ "$MODEL_NUM" = "CGA4332COM" ] || [ "$MODEL_NUM" = "CGA4131COM" ]; then
        	if [ "$isBridging" = "3" ]; then
            		echo_t "[RDKB_SELFHEAL] : Device in Basic Bridge mode"
        	elif [ "$isBridging" = "2" ]; then
            		echo_t "[RDKB_SELFHEAL] : Device in Advanced Bridge mode"
       		fi
        fi
    fi

    case $SELFHEAL_TYPE in
        "BASE"|"TCCBR")
            pandm_timeout=$(echo "$bridgeMode" | grep "$CCSP_ERR_TIMEOUT")
            pandm_notexist=$(echo "$bridgeMode" | grep "$CCSP_ERR_NOT_EXIST")
            pandm_notconnect=$(echo "$bridgeMode" | grep "$CCSP_ERR_NOT_CONNECT")
            if [ "$pandm_timeout" != "" ] || [ "$pandm_notexist" != "" ] || [ "$pandm_notconnect" != "" ]; then
                echo_t "[RDKB_PLATFORM_ERROR] : pandm parameter timed out or failed to return"
                cr_query=$(dmcli eRT getv com.cisco.spvtg.ccsp.pam.Name)
                cr_timeout=$(echo "$cr_query" | grep "$CCSP_ERR_TIMEOUT")
                cr_pam_notexist=$(echo "$cr_query" | grep "$CCSP_ERR_NOT_EXIST")
                cr_pam_notconnect=$(echo "$cr_query" | grep "$CCSP_ERR_NOT_CONNECT")
                if [ "$cr_timeout" != "" ] || [ "$cr_pam_notexist" != "" ] || [ "$cr_pam_notconnect" != "" ]; then
                    echo_t "[RDKB_PLATFORM_ERROR] : pandm process is not responding. Restarting it"
                    t2CountNotify "SYS_ERROR_PnM_Not_Responding"
                    PANDM_PID=$(busybox pidof CcspPandMSsp)
                    if [ "$PANDM_PID" != "" ]; then
                        kill -9 "$PANDM_PID"
                    fi
                    case $SELFHEAL_TYPE in
                        "BASE"|"TCCBR")
                            rm -rf /tmp/pam_initialized
                            resetNeeded pam CcspPandMSsp
                        ;;
                        "SYSTEMD")
                        ;;
                    esac
                fi  # [ "$cr_timeout" != "" ] || [ "$cr_pam_notexist" != "" ]
            fi  # [ "$pandm_timeout" != "" ] || [ "$pandm_notexist" != "" ]
        ;;
        "SYSTEMD")
            pandm_timeout=$(echo "$bridgeMode" | grep "$CCSP_ERR_TIMEOUT")
            if [ "$pandm_timeout" != "" ]; then
                echo_t "[RDKB_PLATFORM_ERROR] : pandm parameter time out"
                cr_query=$(dmcli eRT getv com.cisco.spvtg.ccsp.pam.Name)
                cr_timeout=$(echo "$cr_query" | grep "$CCSP_ERR_TIMEOUT")
                if [ "$cr_timeout" != "" ]; then
                    echo_t "[RDKB_PLATFORM_ERROR] : pandm process is not responding. Restarting it"
                    t2CountNotify "SYS_ERROR_PnM_Not_Responding"
                    PANDM_PID=$(busybox pidof CcspPandMSsp)
                    rm -rf /tmp/pam_initialized
                    systemctl restart CcspPandMSsp.service
                fi
            else
                echo "$bridgeMode"
            fi
        ;;
    esac
fi  # [ "$bridgeSucceed" != "" ]

# Checking PSM's PID
PSM_PID=$(busybox pidof PsmSsp)
if [ "$PSM_PID" = "" ]; then
    case $SELFHEAL_TYPE in
        "BASE"|"TCCBR")
            #       echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : PSM_process is not running, need to reboot the unit"
            #       echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : PSM_process is not running, need to reboot the unit"
            #       vendor=$(getVendorName)
            #       modelName=$(getModelName)
            #       CMMac=$(getCMMac)
            #       timestamp=$(getDate)
            #       echo "[$(getDateTime)] Setting Last reboot reason"
            #       dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootReason string Psm_crash
            #       dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootCounter int 1
            #       echo "[$(getDateTime)] SET succeeded"
            #       echo "[$(getDateTime)] RDKB_SELFHEAL : <$level>CABLEMODEM[$vendor]:<99000007><$timestamp><$CMMac><$modelName> RM PsmSsp process died,need reboot"
            #       touch $HAVECRASH
            #       rebootNeeded RM "PSM"

            if [ ! -f "$PSM_SHUTDOWN" ];then
                echo_t "RDKB_PROCESS_CRASHED : PSM_process is not running, need restart"
                resetNeeded psm PsmSsp
            fi
        ;;
        "SYSTEMD")
        ;;
    esac
else
    psm_name=$(dmcli eRT getv com.cisco.spvtg.ccsp.psm.Name)
    psm_name_timeout=$(echo "$psm_name" | grep "$CCSP_ERR_TIMEOUT")
    psm_name_notexist=$(echo "$psm_name" | grep "$CCSP_ERR_NOT_EXIST")
    psm_name_notconnect=$(echo "$psm_name" | grep "$CCSP_ERR_NOT_CONNECT")
    if [ "$psm_name_timeout" != "" ] || [ "$psm_name_notexist" != "" ] || [ "$psm_name_notconnect" != "" ]; then
        psm_health=$(dmcli eRT getv com.cisco.spvtg.ccsp.psm.Health)
        psm_health_timeout=$(echo "$psm_health" | grep "$CCSP_ERR_TIMEOUT")
        psm_health_notexist=$(echo "$psm_health" | grep "$CCSP_ERR_NOT_EXIST")
        psm_health_notconnect=$(echo "$psm_health" | grep "$CCSP_ERR_NOT_CONNECT")
        if [ "$psm_health_timeout" != "" ] || [ "$psm_health_notexist" != "" ] || [ "$psm_health_notconnect" != "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : PSM_process is in hung state, need restart"
            t2CountNotify "SYS_SH_PSMHung"
            case $SELFHEAL_TYPE in
                "BASE"|"TCCBR")
                    kill -9 "$(busybox pidof PsmSsp)"
                    resetNeeded psm PsmSsp
                ;;
                "SYSTEMD")
                    systemctl restart PsmSsp.service
                ;;
            esac
        fi
    fi
fi

case $SELFHEAL_TYPE in
    "BASE")
        PAM_PID=$(busybox pidof CcspPandMSsp)
        if [ "$PAM_PID" = "" ]; then
            # Remove the P&M initialized flag
            rm -rf /tmp/pam_initialized
            echo_t "RDKB_PROCESS_CRASHED : PAM_process is not running, need restart"
            t2CountNotify "SYS_SH_PAM_CRASH_RESTART"
            resetNeeded pam CcspPandMSsp
        fi

        # Checking MTA's PID
        if [ "$MODEL_NUM" = "DPC3939B" ] || [ "$MODEL_NUM" = "DPC3941B" ] || [ "$VOICE_SUPPORTED" != "false" ]; then
            echo_t "BWG doesn't support voice"
        else
            MTA_PID=$(busybox pidof CcspMtaAgentSsp)
            if [ "$MTA_PID" = "" ]; then
                #       echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : MTA_process is not running, restarting it"
                echo_t "RDKB_PROCESS_CRASHED : MTA_process is not running, need restart"
                resetNeeded mta CcspMtaAgentSsp
                t2CountNotify "SYS_SH_MTA_restart"
            fi
        fi

        # Checking CM's PID
        if [ "$WAN_TYPE" != "EPON" ]; then
            CM_PID=$(busybox pidof CcspCMAgentSsp)
            if [ "$CM_PID" = "" ]; then
                #           echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : CM_process is not running, restarting it"
                echo_t "RDKB_PROCESS_CRASHED : CM_process is not running, need restart"
                resetNeeded cm CcspCMAgentSsp
            fi
        else
            #Checking EPONAgent is running.
            EPON_AGENT_PID=$(busybox pidof CcspEPONAgentSsp)
            if [ "$EPON_AGENT_PID" = "" ]; then
                echo_t "RDKB_PROCESS_CRASHED : EPON_process is not running, need restart"
                resetNeeded epon CcspEPONAgentSsp
            fi
        fi

        # Checking WEBController's PID
        #   WEBC_PID=$(busybox pidof CcspWecbController)
        #   if [ "$WEBC_PID" = "" ]; then
        #       echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : WECBController_process is not running, restarting it"
        #       echo_t "RDKB_PROCESS_CRASHED : WECBController_process is not running, need restart"
        #       resetNeeded wecb CcspWecbController
        #   fi

        # Checking RebootManager's PID
        #   Rm_PID=$(busybox pidof CcspRmSsp)
        #   if [ "$Rm_PID" = "" ]; then
        #   echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : RebootManager_process is not running, restarting it"
        #       echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : RebootManager_process is not running, need restart"
        #       resetNeeded "rm" CcspRmSsp

        #   fi

        # Checking TR69's PID
        if [ "$MODEL_NUM" = "DPC3939B" ] || [ "$MODEL_NUM" = "DPC3941B" ] || [ "$MODEL_NUM" = "CGA4332COM" ]; then
            echo_t "BWG doesn't support TR069Pa "
        else
            TR69_PID=$(busybox pidof CcspTr069PaSsp)
            enable_TR69_Binary=$(syscfg get EnableTR69Binary)
            if [ "" = "$enable_TR69_Binary" ] || [ "true" = "$enable_TR69_Binary" ]; then
                if [ "$TR69_PID" = "" ]; then
                    echo_t "RDKB_PROCESS_CRASHED : TR69_process is not running, need restart"
                    t2CountNotify "SYS_SH_TR69Restart"
                    resetNeeded TR69 CcspTr069PaSsp
                fi
            fi
        fi

        # Checking Test adn Daignostic's PID
        TandD_PID=$(busybox pidof CcspTandDSsp)
        if [ "$TandD_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : TandD_process is not running, need restart"
            resetNeeded tad CcspTandDSsp
        fi

        # Checking Lan Manager PID
        LM_PID=$(busybox pidof CcspLMLite)
        if [ "$LM_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : LanManager_process is not running, need restart"
            t2CountNotify "SYS_SH_LM_restart"
            resetNeeded lm CcspLMLite
        else
            cr_query=$(dmcli eRT getv com.cisco.spvtg.ccsp.lmlite.Name)
            cr_timeout=$(echo "$cr_query" | grep "$CCSP_ERR_TIMEOUT")
            cr_lmlite_notexist=$(echo "$cr_query" | grep "$CCSP_ERR_NOT_EXIST")
            if [ "$cr_timeout" != "" ] || [ "$cr_lmlite_notexist" != "" ]; then
                echo_t "[RDKB_PLATFORM_ERROR] : LMlite process is not responding. Restarting it"
                kill -9 "$(busybox pidof CcspLMLite)"
                resetNeeded lm CcspLMLite
            fi
        fi

        # Checking XdnsSsp PID
        XDNS_PID=$(busybox pidof CcspXdnsSsp)
        if [ "$XDNS_PID" = "" ] && [ "$BOX_TYPE" != "bpi" ]; then
            echo_t "RDKB_PROCESS_CRASHED : CcspXdnsSsp_process is not running, need restart"
            resetNeeded xdns CcspXdnsSsp

        fi

        # Checking CcspEthAgent PID
        ETHAGENT_PID=$(busybox pidof CcspEthAgent)
        if [ "$ETHAGENT_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : CcspEthAgent_process is not running, need restart"
            resetNeeded ethagent CcspEthAgent

        fi

        # Checking snmp v2 subagent PID
        if [ -f "/etc/SNMP_PA_ENABLE" ]; then
            SNMP_PID=$(ps -ww | grep "snmp_subagent" | grep -v "cm_snmp_ma_2" | grep -v "grep" | awk '{print $1}')
            if [ "$SNMP_PID" = "" ]; then
                if [ -f /tmp/.snmp_agent_restarting ]; then
                    echo_t "[RDKB_SELFHEAL] : snmp process is restarted through maintanance window"
                else
                    SNMPv2_RDKB_MIBS_SUPPORT=$(syscfg get V2Support)
                    if [ "$SNMPv2_RDKB_MIBS_SUPPORT" = "true" ] || [ "$SNMPv2_RDKB_MIBS_SUPPORT" = "" ]; then
                        echo_t "RDKB_PROCESS_CRASHED : snmp process is not running, need restart"
                        t2CountNotify "SYS_SH_SNMP_NotRunning"
                        resetNeeded snmp snmp_subagent
                    fi
                fi
            fi
        fi

        # Checking CcspMoCA PID
        MOCA_PID=$(busybox pidof CcspMoCA)
        if [ "$MOCA_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : CcspMoCA process is not running, need restart"
            resetNeeded moca CcspMoCA
        fi
		
	 #Checking notify_component PID
	 NOTIFY_PID=$(busybox pidof notify_comp)
	 if [ "$NOTIFY_PID" = "" ]; then
		 echo_t "RDKB_PROCESS_CRASHED : notify_comp is not running, need restart"
		 resetNeeded notify-comp notify_comp
	 fi

        if [ "$MODEL_NUM" = "DPC3939" ] || [ "$MODEL_NUM" = "DPC3941" ]; then
            # Checking mocadlfw PID
            MOCADLFW_PID=$(busybox pidof mocadlfw)
            if [ "$MOCADLFW_PID" = "" ]; then
                echo_t "OEM_PROCESS_MOCADLFW_CRASHED : mocadlfw process is not running, need restart"
                /usr/sbin/mocadlfw > /dev/null 2>&1 &
            fi
        fi

	# BWGRDK-1384: Selfheal mechanism for ripd process
	if [ "$MODEL_NUM" = "DPC3939B" ] || [ "$MODEL_NUM" = "DPC3941B" ]; then
	    staticIp_check=$(psmcli get dmsb.truestaticip.Enable)
            if [ "$staticIp_check" = "1" ]; then
		ripdPid=$(busybox pidof ripd)
		if [ -z "$ripdPid" ]; then
                    echo_t "RDKB_SELFHEAL : ripd process is not running, need restart"
                    /usr/sbin/ripd -d -f /var/ripd.conf -u root -g root -i /var/ripd.pid &
		fi
	    fi
	fi
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
        XDNS_ENABLED=$(syscfg get X_RDKCENTRAL-COM_XDNS)

        if [ "x$XDNS_ENABLED" = "x1" ] && [ $(grep dnsoverride /etc/resolv.conf | wc -l) -eq 0 ]; then
            RESTART_COUNT_FILE="/tmp/xdns_selfheal_restart_count"
            RESTART_COUNT=0
            # Initialize the restart count file if it doesn't exist
            if [ ! -f $RESTART_COUNT_FILE ]; then
                echo 0 > $RESTART_COUNT_FILE
            else
                RESTART_COUNT=$(cat $RESTART_COUNT_FILE)
                if [ $RESTART_COUNT -eq 3 ]; then
                    xdnsRetryCountLastUpdated=$(date +%s -r $RESTART_COUNT_FILE)
                    currentTime=$(date +%s)
                    timeDiff=$((currentTime-xdnsRetryCountLastUpdated))
                    MAX_TIME_DIFF=86400 # 24 hours
                    if [ "$timeDiff" -gt "$MAX_TIME_DIFF" ]; then
                        echo_t "XDNS restart retry count reset"
                        echo 0 > $RESTART_COUNT_FILE
                    fi
                fi
            fi

            RESTART_COUNT=$(cat $RESTART_COUNT_FILE)
            if [ $RESTART_COUNT -lt 3 ]; then
                echo_t "Missing dnsoverride entries in resolv.conf with XDNS feature enabled. Restarting XDNS"
                t2CountNotify "SYS_SH_XDNS_dnsoverride_miss_restart"
                systemctl restart CcspXdnsSsp
                RESTART_COUNT=$((RESTART_COUNT + 1))
                echo $RESTART_COUNT > $RESTART_COUNT_FILE
            else
                echo_t "dnsoverride entries didn't populate even after three retries of XDNS restarts"
                t2CountNotify "SYS_SH_XDNS_dnsoverride_populate_fail"
            fi
        fi
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
        case $BOX_TYPE in
            "HUB4"|"SR300"|"SE501"|"SR213"|"WNXL11BWL")
                Harvester_PID=$(busybox pidof harvester)
                if [ "$Harvester_PID" != "" ]; then
                    Harvester_CPU=$(top -bn1 | grep "harvester" | grep -v "grep" | head -n5 | awk -F'%' '{print $2}' | sed -e 's/^[ \t]*//' | awk '{$1=$1};1')
                    if [ "$Harvester_CPU" != "" ] && [ $Harvester_CPU -ge 30 ]; then
                        echo_t "[RDKB_PLATFORM_ERROR] : harvester process is hung and taking $Harvester_CPU% CPU, restarting it"
                        systemctl restart harvester.service
                    fi
                fi
            ;;
        esac
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
        OS_WANMANGR_ENABLE_FILE=/tmp/OS_WANMANAGER_ENABLED
        OS_WANMANGR_DIR=/usr/rdk/wanmanager/wanmanager

        if [ -f $OS_WANMANGR_ENABLE_FILE ];then
            echo_t "os-wanmanager enabled"
            if [ -f $OS_WANMANGR_DIR ];then
                # Checking wanmanager's PID
                for ((val=1;val<12;val++))
                do
                    WANMANAGER_PID=$(busybox pidof wanmanager)
                    if [ "$WANMANAGER_PID" = "" ]; then
                        echo_t "WANMANAGER_process is not running, check after 5sec. retry : $val"
                        sleep 5
                    else
                        echo_t "wanmanager process found $WANMANAGER_PID "
                        break;
                    fi
                done
                if [ "$WANMANAGER_PID" = "" ]; then
                    echo_t "RDKB_PROCESS_CRASHED : WANMANAGER_process is not running, need CPE reboot"
                    t2CountNotify "SYS_ERROR_wanmanager_crash_reboot"
                    reason="wanmanager_crash"
                    rebootCount=1
                    rebootNeeded RM "WANMANAGER" $reason $rebootCount
                fi
            fi
        fi
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
        WiFi_Flag=false
        WiFi_PID=$(busybox pidof CcspWifiSsp)
        if [ "$WiFi_PID" != "" ]; then
            radioenable=$(dmcli eRT getv Device.WiFi.Radio.1.Enable)
            radioenable_timeout=$(echo "$radioenable" | grep "$CCSP_ERR_TIMEOUT")
            radioenable_notexist=$(echo "$radioenable" | grep "$CCSP_ERR_NOT_EXIST")
            if [ "$radioenable_timeout" != "" ] || [ "$radioenable_notexist" != "" ]; then
                wifi_name=$(dmcli eRT getv com.cisco.spvtg.ccsp.wifi.Name)
                wifi_name_timeout=$(echo "$wifi_name" | grep "$CCSP_ERR_TIMEOUT")
                wifi_name_notexist=$(echo "$wifi_name" | grep "$CCSP_ERR_NOT_EXIST")
                if [ "$wifi_name_timeout" != "" ] || [ "$wifi_name_notexist" != "" ]; then
                    if [ "$BOX_TYPE" = "XB6" ]; then
                        if [ -f "$thisREADYFILE" ]; then
                            echo_t "[RDKB_PLATFORM_ERROR] : CcspWifiSsp process is hung , restarting it"
                            systemctl restart ccspwifiagent
                            WiFi_Flag=true
                            t2CountNotify "WIFI_SH_CcspWifiHung_restart"
                        fi
                    else
                        echo_t "[RDKB_PLATFORM_ERROR] : CcspWifiSsp process is hung , restarting it"
                        t2CountNotify "WIFI_SH_CcspWifiHung_restart"
                        systemctl restart ccspwifiagent
                        WiFi_Flag=true
                    fi
                fi
            fi
        fi
    ;;
esac

CcspHome_Security=`sysevent get HomeSecuritySupport`
if [ "$MODEL_NUM" = "DPC3939B" ] || [ "$MODEL_NUM" = "DPC3941B" ]; then
    echo_t "Disabling CcspHomeSecurity and CcspAdvSecurity for BWG"
elif [ "$MODEL_NUM" = "CVA601ZCOM" ]; then
    echo_t "Disabling CcspHomeSecurity and CcspAdvSecurity for XD4 "
else
    if [ "$MODEL_NUM" = "CGA4332COM" ]; then
        echo_t "CcspHomeSecurity disabled for CBRv2 "
    fi
    if [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ]  && [ "$BOX_TYPE" != "SR213" ] && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ "$CcspHome_Security" != "false" ] && [ "$MODEL_NUM" != "CGA4332COM" ]; then
        
        case $SELFHEAL_TYPE in
            "BASE"|"SYSTEMD")

                HOMESEC_PID=$(busybox pidof CcspHomeSecurity)
                if [ "$HOMESEC_PID" = "" ]; then
                    case $SELFHEAL_TYPE in
                        "BASE")
                            echo_t "RDKB_PROCESS_CRASHED : HomeSecurity_process is not running, need restart"
                            t2CountNotify "SYS_SH_HomeSecurity_restart"
                        ;;
                        "TCCBR")
                        ;;
                        "SYSTEMD")
                            echo_t "RDKB_PROCESS_CRASHED : HomeSecurity process is not running, need restart"
                            t2CountNotify "SYS_SH_HomeSecurity_restart"
                        ;;
                    esac
                    resetNeeded "" CcspHomeSecurity
                fi
	esac

    fi #Not HUb4

                isADVPID=0
                case $SELFHEAL_TYPE in
                    "BASE")
                        # CcspAdvSecurity
                        ADV_PID=$(busybox pidof CcspAdvSecuritySsp)
                        if [ "$ADV_PID" = "" ] ; then
                            echo_t "RDKB_PROCESS_CRASHED : CcspAdvSecurity_process is not running, need restart"
                            resetNeeded advsec CcspAdvSecuritySsp
                            isADVPID=1
                        fi
                    ;;
                    "TCCBR")
                    ;;
                    "SYSTEMD")
                    ;;
                esac
                advsec_bridge_mode=$(syscfg get bridge_mode)
                DF_ENABLED=$(syscfg get Advsecurity_DeviceFingerPrint)
                if [ "$advsec_bridge_mode" != "2" ]; then
                    if [ -f $ADVSEC_PATH ]; then
                        if [ $isADVPID -eq 0 ] && [ "$DF_ENABLED" = "1" ]; then
                            if [ "x$(advsec_is_agent_installed)" == "xYES" ]; then
                                if [ ! -f $ADVSEC_INITIALIZING ]; then
                                    ADV_AGENT_PID=$(advsec_is_alive ${CUJO_AGENT})
                                    if [ "${ADV_AGENT_PID}" = "" ] ; then
                                        if  [ ! -e ${ADVSEC_AGENT_SHUTDOWN} ] && [ ! -e ${ADVSEC_AGENT_SHUTDOWN_COMPLETE} ]; then
                                            echo_t "RDKB_PROCESS_CRASHED : AdvSecurity ${CUJO_AGENT_LOG} process is not running, need restart"
                                        fi
                                        resetNeeded advsec_bin AdvSecurityAgent
                                    fi
                                fi
                            fi
                        fi
                    else
                        case $SELFHEAL_TYPE in
                            "BASE")
                                if [ "$MODEL_NUM" = "DPC3941" ]; then
                                    /usr/sbin/cujo_download.sh &
                                fi
                            ;;
                            "TCCBR")
                            ;;
                            "SYSTEMD")
                            ;;
                        esac
                    fi  # [ -f $ADVSEC_PATH ]
                    # cujo-qosd
                    NI_ENABLED=$(dmcli eRT retv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.NetworkIntelligence.Enable)
                    if [ "$NI_ENABLED" = "true" ]; then
                        NI_PID=$(pidof cujo-qosd)
                        if [ "$NI_PID" = "" ] ; then
                            echo_t "RDKB_PROCESS_CRASHED : cujo-qosd process is not running, need restart"
                            resetNeeded "" cujo-qosd
                        fi
                    fi
                fi  # [ "$advsec_bridge_mode" != "2" ]
fi #BWG
case $SELFHEAL_TYPE in
    "BASE")
    ;;
    "TCCBR")

        atomOnlyReboot=$(dmesg -n 8 && dmesg | grep -i "Atom only")
        if [ "x$atomOnlyReboot" = "x" ]; then
            crTestop=$(dmcli eRT getv com.cisco.spvtg.ccsp.CR.Name)
            isCRAlive=$(echo "$crTestop" | grep "Can't find destination compo")
            if [ "$isCRAlive" != "" ]; then
                # Retest by querying some other parameter
                crReTestop=$(dmcli eRT getv Device.X_CISCO_COM_DeviceControl.DeviceMode)
                isCRAlive=$(echo "$crReTestop" | grep "Can't find destination compo")
                if [ "$isCRAlive" != "" ]; then
                    #echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : CR_process is not running, need to reboot the unit"
                    echo_t "RDKB_PROCESS_CRASHED : CR_process is not running, need to reboot the unit"
                    vendor=$(getVendorName)
                    modelName=$(getModelName)
                    CMMac=$(getCMMac)
                    timestamp=$(getDate)
                    echo_t "Setting Last reboot reason"
                    reason="CR_crash"
                    rebootCount=1
                    setRebootreason $reason $rebootCount
                    echo_t "SET succeeded"
                    echo_t "RDKB_SELFHEAL : <$level>CABLEMODEM[$vendor]:<99000007><$timestamp><$CMMac><$modelName> RM CcspCrSsp process died,need reboot"
                    touch $HAVECRASH
                    rebootNeeded RM "CR"
                fi
            fi
        else
            echo_t "[RDKB_SELFHEAL] : Atom only reboot is triggered"
        fi

        ###########################################


        PAM_PID=$(busybox pidof CcspPandMSsp)
        if [ "$PAM_PID" = "" ]; then
            # Remove the P&M initialized flag
            rm -rf /tmp/pam_initialized
            echo_t "RDKB_PROCESS_CRASHED : PAM_process is not running, need restart"
            resetNeeded pam CcspPandMSsp
            t2CountNotify "SYS_SH_PAM_CRASH_RESTART"
        fi

	if [ "$VOICE_SUPPORTED" != "false" ]; then
        # Checking MTA's PID
        MTA_PID=$(busybox pidof CcspMtaAgentSsp)
        if [ "$MTA_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : MTA_process is not running, need restart"
            resetNeeded mta CcspMtaAgentSsp
            t2CountNotify "SYS_SH_MTA_restart"
        fi
	fi

        WiFi_Flag=false
        # Checking Wifi's PID
        WIFI_PID=$(busybox pidof CcspWifiSsp)
        if [ "$WIFI_PID" = "" ]; then
            # Remove the wifi initialized flag
            rm -rf /tmp/wifi_initialized
            echo_t "RDKB_PROCESS_CRASHED : WIFI_process is not running, need restart"
            resetNeeded wifi CcspWifiSsp
        else
            radioenable=$(dmcli eRT getv Device.WiFi.Radio.1.Enable)
            radioenable_timeout=$(echo "$radioenable" | grep "$CCSP_ERR_TIMEOUT")
            radioenable_notexist=$(echo "$radioenable" | grep "$CCSP_ERR_NOT_EXIST")
            if [ "$radioenable_timeout" != "" ] || [ "$radioenable_notexist" != "" ]; then
                wifi_name=$(dmcli eRT getv com.cisco.spvtg.ccsp.wifi.Name)
                wifi_name_timeout=$(echo "$wifi_name" | grep "$CCSP_ERR_TIMEOUT")
                wifi_name_notexist=$(echo "$wifi_name" | grep "$CCSP_ERR_NOT_EXIST")
                if [ "$wifi_name_timeout" != "" ] || [ "$wifi_name_notexist" != "" ]; then
                    echo_t "[RDKB_PLATFORM_ERROR] : CcspWifiSsp process is hung , restarting it"
                    t2CountNotify "WIFI_SH_CcspWifiHung_restart"
                    # Remove the wifi initialized flag
                    rm -rf /tmp/wifi_initialized

                    #TCCBR-4286 Workaround for wifi process hung
                    sh $TAD_PATH/oemhooks.sh "CCSP_WIFI_HUNG"

                    resetNeeded wifi CcspWifiSsp
                    WiFi_Flag=true
                fi
            fi
        fi

        if [ -f /tmp/wifi_eapd_restart_required ] ; then
            echo_t "RDKB_PROCESS_CRASHED : eapd wifi process needs restart"
            killall eapd
            #starting the eapd process
            eapd
            rm -rf /tmp/wifi_eapd_restart_required
        fi

        # Checking CM's PID
        CM_PID=$(busybox pidof CcspCMAgentSsp)
        if [ "$CM_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : CM_process is not running, need restart"
            resetNeeded cm CcspCMAgentSsp
        fi

        # Checking WEBController's PID
        #   WEBC_PID=$(busybox pidof CcspWecbController)
        #   if [ "$WEBC_PID" = "" ]; then
        #       echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : WECBController_process is not running, restarting it"
        #       echo_t "RDKB_PROCESS_CRASHED : WECBController_process is not running, need restart"
        #       resetNeeded wecb CcspWecbController
        #   fi

        # Checking RebootManager's PID
        #   Rm_PID=$(busybox pidof CcspRmSsp)
        #   if [ "$Rm_PID" = "" ]; then
        #       echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : RebootManager_process is not running, restarting it"
        #       echo "[$(getDateTime)] RDKB_PROCESS_CRASHED : RebootManager_process is not running, need restart"
        #       resetNeeded "rm" CcspRmSsp

        #   fi

        # Checking Test adn Daignostic's PID
        TandD_PID=$(busybox pidof CcspTandDSsp)
        if [ "$TandD_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : TandD_process is not running, need restart"
            resetNeeded tad CcspTandDSsp
        fi

        # Checking Lan Manager PID
        LM_PID=$(busybox pidof CcspLMLite)
        if [ "$LM_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : LanManager_process is not running, need restart"
            t2CountNotify "SYS_SH_LM_restart"
            resetNeeded lm CcspLMLite

        fi

        # Checking XdnsSsp PID
        XDNS_PID=$(busybox pidof CcspXdnsSsp)

        XDNS_ENABLED=$(syscfg get X_RDKCENTRAL-COM_XDNS)

        if [ "$XDNS_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : CcspXdnsSsp_process is not running, need restart"
            resetNeeded xdns CcspXdnsSsp
        elif [ "x$XDNS_ENABLED" = "x1" ] && [ $(grep dnsoverride /etc/resolv.conf | wc -l) -eq 0 ]; then
            RESTART_COUNT_FILE="/tmp/xdns_selfheal_restart_count"
            RESTART_COUNT=0
            # Initialize the restart count file if it doesn't exist
            if [ ! -f $RESTART_COUNT_FILE ]; then
                echo 0 > $RESTART_COUNT_FILE
            else
                RESTART_COUNT=$(cat $RESTART_COUNT_FILE)
                if [ $RESTART_COUNT -eq 3 ]; then
                    xdnsRetryCountLastUpdated=$(date +%s -r $RESTART_COUNT_FILE)
                    currentTime=$(date +%s)
                    timeDiff=$((currentTime-xdnsRetryCountLastUpdated))
                    MAX_TIME_DIFF=86400 # 24 hours
                    if [ "$timeDiff" -gt "$MAX_TIME_DIFF" ]; then
                        echo_t "XDNS restart retry count reset"
                        echo 0 > $RESTART_COUNT_FILE
                    fi
                fi
            fi

            RESTART_COUNT=$(cat $RESTART_COUNT_FILE)
            if [ $RESTART_COUNT -lt 3 ]; then
                echo_t "Missing dnsoverride entries in resolv.conf with XDNS feature enabled. Restarting XDNS"
                t2CountNotify "SYS_SH_XDNS_dnsoverride_miss_restart"
                systemctl restart CcspXdnsSsp
                RESTART_COUNT=$((RESTART_COUNT + 1))
                echo $RESTART_COUNT > $RESTART_COUNT_FILE
            else
                echo_t "dnsoverride entries didn't populate even after three retries of XDNS restarts"
                t2CountNotify "SYS_SH_XDNS_dnsoverride_populate_fail"
            fi

        fi

        # Checking CcspEthAgent PID
        ETHAGENT_PID=$(busybox pidof CcspEthAgent)
        if [ "$ETHAGENT_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : CcspEthAgent_process is not running, need restart"
            resetNeeded ethagent CcspEthAgent

        fi

        # Checking snmp subagent PID
        if [ -f "/etc/SNMP_PA_ENABLE" ]; then
            SNMP_PID=$(busybox pidof snmp_subagent)
            if [ "$SNMP_PID" = "" ]; then
                echo_t "RDKB_PROCESS_CRASHED : snmp process is not running, need restart"
                t2CountNotify "SYS_SH_SNMP_NotRunning"
                resetNeeded snmp snmp_subagent
            fi
        fi
		
	 #Checking notify_component PID
	 NOTIFY_PID=$(busybox pidof notify_comp)
	 if [ "$NOTIFY_PID" = "" ]; then
		 echo_t "RDKB_PROCESS_CRASHED : notify_comp is not running, need restart"
		 resetNeeded notify-comp notify_comp
	 fi

        # Checking harvester PID
        HARVESTER_PID=$(busybox pidof harvester)
        if [ "$HARVESTER_PID" = "" ]; then
            echo_t "RDKB_PROCESS_CRASHED : harvester is not running, need restart"
            resetNeeded harvester harvester
        fi
    ;;
    "SYSTEMD")
    ;;
esac

HOTSPOT_ENABLE=$(dmcli eRT getv Device.DeviceInfo.X_COMCAST_COM_xfinitywifiEnable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")

if [ "$thisWAN_TYPE" != "EPON" ] && [ "$HOTSPOT_ENABLE" = "true" ] && [ ! -f /tmp/.hotspot_blob_inprogress ]; then
    DHCP_ARP_PID=$(busybox pidof hotspot_arpd)
    if [ "$DHCP_ARP_PID" = "" ] && [ -f /tmp/hotspot_arpd_up ] && [ ! -f /tmp/tunnel_destroy_flag ] ; then
        echo_t "RDKB_PROCESS_CRASHED : DhcpArp_process is not running, need restart"
        t2CountNotify "SYS_SH_DhcpArpProcess_restart"
        resetNeeded "" hotspot_arpd
    fi

    HOTSPOT_PID=$(busybox pidof CcspHotspot)
    if [ "$HOTSPOT_PID" = "" ]; then
        if [ ! -f /tmp/tunnel_destroy_flag ] ; then

            primary=$(sysevent get hotspotfd-primary)
            secondary=$(sysevent get hotspotfd-secondary)
            keepalive_interval=$(sysevent get hotspotfd-keep-alive)
            PRIMARY_EP=$(dmcli eRT getv Device.X_COMCAST-COM_GRE.Tunnel.1.PrimaryRemoteEndpoint | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
            SECOND_EP=$(dmcli eRT getv Device.X_COMCAST-COM_GRE.Tunnel.1.SecondaryRemoteEndpoint | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
            WAN_STATUS=$(sysevent get wan-status)
            if [ "$primary" = "" ] ; then
               echo_t "Primary endpoint is empty. Restoring it"
               sysevent set hotspotfd-primary $PRIMARY_EP
            fi

            if [ "$secondary" = "" ] ; then
               echo_t "Secondary endpoint is empty. Restoring it"
               sysevent set hotspotfd-secondary $SECOND_EP
            fi
            if [ "$WAN_STATUS" = "started" ] ; then
                if [ "$keepalive_interval" = "" ] ; then
                   echo_t "KeepAlive Parameters are not set"
                   sysevent set hotspot-start
                else
                   resetNeeded "" CcspHotspot
                fi
            else
                echo_t "Not Starting CcspHotspot since WAN is not started"
            fi
        fi
    fi
fi

case $SELFHEAL_TYPE in
    "BASE")
        if [ "$WAN_TYPE" != "EPON" ] && [ "$HOTSPOT_ENABLE" = "true" ]; then
            rcount=0
            OPEN_24=$(dmcli eRT getv Device.WiFi.SSID.5.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
            OPEN_5=$(dmcli eRT getv Device.WiFi.SSID.6.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
            #When Xfinitywifi is enabled, l2sd0.102 and l2sd0.103 should be present.
            #If they are not present below code shall re-create them
            #l2sd0.102 case , also adding a strict rule that they are up, since some
            #devices we observed l2sd0 not up

            if [ "$MODEL_NUM" = "DPC3939B" ]; then
		Xfinity_Open_24_VLANID="2312"
		Xfinity_Open_5_VLANID="2315"
		Xfinity_Secure_24_VLANID="2311"
		Xfinity_Secure_5_VLANID="2314"
		Xfinity_Public_5_VLANID="2316"
	    elif [ "$MODEL_NUM" = "DPC3941B" ]; then
		Xfinity_Open_24_VLANID="2322"
		Xfinity_Open_5_VLANID="2325"
		Xfinity_Secure_24_VLANID="2321"
		Xfinity_Secure_5_VLANID="2324"
		Xfinity_Public_5_VLANID="2326"
	    else
		Xfinity_Open_24_VLANID="102"
		Xfinity_Open_5_VLANID="103"
		Xfinity_Secure_24_VLANID="104"
		Xfinity_Secure_5_VLANID="105"
	    fi
        if [ "$OPEN_24" = "true" ]; then
            grePresent=$(ifconfig -a | grep "$grePrefix\.$Xfinity_Open_24_VLANID")
			if [ "x$ovs_enable" = "xtrue" ];then
				brPresent=$(ovs-vsctl show | grep "brlan2")
			else
				brPresent=$(brctl show | grep "brlan2")
			fi
            
            if [ "$grePresent" = "" ] || [ "$brPresent" = "" ] ; then
                ifconfig | grep "$l2sd0Prefix\.$Xfinity_Open_24_VLANID"
                if [ $? -eq 1 ]; then
                    echo_t "XfinityWifi is enabled, but $l2sd0Prefix.$Xfinity_Open_24_VLANID interface is not created try creating it"

                    Interface=$(psmcli get dmsb.l2net.3.Members.WiFi)
                    if [ "$Interface" = "" ]; then
                        echo_t "PSM value(ath4) is missing for $l2sd0Prefix.$Xfinity_Open_24_VLANID"
                        psmcli set dmsb.l2net.3.Members.WiFi ath4
                    fi

                    sysevent set multinet_3-status stopped
                    $UTOPIA_PATH/service_multinet_exec multinet-start 3
                    ifconfig $l2sd0Prefix.$Xfinity_Open_24_VLANID up
                    ifconfig | grep "$l2sd0Prefix\.$Xfinity_Open_24_VLANID"
                    if [ $? -eq 1 ]; then
                        echo_t "$l2sd0Prefix.$Xfinity_Open_24_VLANID is not created at First Retry, try again after 2 sec"
                        sleep 2
                        sysevent set multinet_3-status stopped
                        $UTOPIA_PATH/service_multinet_exec multinet-start 3
                        ifconfig $l2sd0Prefix.$Xfinity_Open_24_VLANID up
                        ifconfig | grep "$l2sd0Prefix\.$Xfinity_Open_24_VLANID"
                        if [ $? -eq 1 ]; then
                            echo_t "[RDKB_PLATFORM_ERROR] : $l2sd0Prefix.$Xfinity_Open_24_VLANID is not created after Second Retry, no more retries !!!"
                        fi
                    else
                        echo_t "[RDKB_PLATFORM_ERROR] : $l2sd0Prefix.$Xfinity_Open_24_VLANID created at First Retry itself"
                    fi
                else
                    echo_t "[RDKB_PLATFORM_ERROR] :XfinityWifi:  SSID 2.4GHz is enabled but gre tunnels not present, restoring it"
                    t2CountNotify "SYS_ERROR_GRETunnel_restored"
                    rcount=1
                fi
            fi
            fi

            #l2sd0.103 case
            if [ "$OPEN_5" = "true" ]; then
            grePresent=$(ifconfig -a | grep "$grePrefix\.$Xfinity_Open_5_VLANID")
			if [ "x$ovs_enable" = "xtrue" ];then
				brPresent=$(ovs-vsctl show | grep "brlan3")
			else
				brPresent=$(brctl show | grep "brlan3")
			fi
            
            if [ "$grePresent" = "" ] || [ "$brPresent" = "" ]; then
                ifconfig | grep "$l2sd0Prefix\.$Xfinity_Open_5_VLANID"
                if [ $? -eq 1 ]; then
                    echo_t "XfinityWifi is enabled, but $l2sd0Prefix.$Xfinity_Open_5_VLANID interface is not created try creatig it"

                    Interface=$(psmcli get dmsb.l2net.4.Members.WiFi)
                    if [ "$Interface" = "" ]; then
                        echo_t "PSM value(ath5) is missing for $l2sd0Prefix.$Xfinity_Open_5_VLANID"
                        psmcli set dmsb.l2net.4.Members.WiFi ath5
                    fi

                    sysevent set multinet_4-status stopped
                    $UTOPIA_PATH/service_multinet_exec multinet-start 4
                    ifconfig $l2sd0Prefix.$Xfinity_Open_5_VLANID up
                    ifconfig | grep "$l2sd0Prefix\.$Xfinity_Open_5_VLANID"
                    if [ $? -eq 1 ]; then
                        echo_t "$l2sd0Prefix.$Xfinity_Open_5_VLANID is not created at First Retry, try again after 2 sec"
                        sleep 2
                        sysevent set multinet_4-status stopped
                        $UTOPIA_PATH/service_multinet_exec multinet-start 4
                        ifconfig $l2sd0Prefix.$Xfinity_Open_5_VLANID up
                        ifconfig | grep "$l2sd0Prefix\.$Xfinity_Open_5_VLANID"
                        if [ $? -eq 1 ]; then
                            echo_t "[RDKB_PLATFORM_ERROR] : $l2sd0Prefix.$Xfinity_Open_5_VLANID is not created after Second Retry, no more retries !!!"
                        fi
                    else
                        echo_t "[RDKB_PLATFORM_ERROR] : $l2sd0Prefix.$Xfinity_Open_5_VLANID created at First Retry itself"
                    fi
                else
                    echo_t "[RDKB_PLATFORM_ERROR] :XfinityWifi:  SSID 5 GHz is enabled but gre tunnels not present, restoring it"
                    t2CountNotify "SYS_ERROR_GRETunnel_restored"
                    rcount=1
                fi
            fi
            fi
            #RDKB-16889: We need to make sure Xfinity hotspot Vlan IDs are attached to the bridges
            #if found not attached , then add the device to bridges
            for index in 2 3 4 5
              do
                grePresent=$(ifconfig -a | grep "$grePrefix.10$index")
                if [ -n "$grePresent" ]; then
                    if [ "x$ovs_enable" = "xtrue" ];then
                    	vlanAdded=$(ovs-vsctl show $brlanPrefix$index | grep "$l2sd0Prefix.10$index")
                    else
                    	vlanAdded=$(brctl show $brlanPrefix$index | grep "$l2sd0Prefix.10$index")
                    fi
                    if [ "$vlanAdded" = "" ]; then
                        echo_t "[RDKB_PLATFORM_ERROR] : Vlan not added $l2sd0Prefix.10$index"
                        if [ "x$bridgeUtilEnable" = "xtrue" || "x$ovs_enable" = "xtrue" ];then
                        	/usr/bin/bridgeUtils add-port $brlanPrefix$index $l2sd0Prefix.10$index
                        else
                        	brctl addif $brlanPrefix$index $l2sd0Prefix.10$index
                        fi
                    fi
                fi
              done

            SECURED_24=$(dmcli eRT getv Device.WiFi.SSID.9.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
            SECURED_5=$(dmcli eRT getv Device.WiFi.SSID.10.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")

            #Check for Secured Xfinity hotspot briges and associate them properly if
            #not proper
            #l2sd0.103 case
            
            #Secured Xfinity 2.4
            if [ "$SECURED_24" = "true" ]; then
            grePresent=$(ifconfig -a | grep "$grePrefix\.$Xfinity_Secure_24_VLANID")
			if [ "x$ovs_enable" = "xtrue" ];then
				brPresent=$(ovs-vsctl show | grep "brlan4")
			else
				brPresent=$(brctl show | grep "brlan4")
            fi
            if [ "$grePresent" = "" ] || [ "$brPresent" = "" ]; then
                ifconfig | grep "$l2sd0Prefix\.$Xfinity_Secure_24_VLANID"
                if [ $? -eq 1 ]; then
                    echo_t "XfinityWifi is enabled Secured gre created, but $l2sd0Prefix.$Xfinity_Secure_24_VLANID interface is not created try creatig it"
                    sysevent set multinet_7-status stopped
                    $UTOPIA_PATH/service_multinet_exec multinet-start 7
                    ifconfig $l2sd0Prefix.$Xfinity_Secure_24_VLANID up
                    ifconfig | grep "$l2sd0Prefix\.$Xfinity_Secure_24_VLANID"
                    if [ $? -eq 1 ]; then
                        echo_t "$l2sd0Prefix.$Xfinity_Secure_24_VLANID is not created at First Retry, try again after 2 sec"
                        sleep 2
                        sysevent set multinet_7-status stopped
                        $UTOPIA_PATH/service_multinet_exec multinet-start 7
                        ifconfig $l2sd0Prefix.$Xfinity_Secure_24_VLANID up
                        ifconfig | grep "$l2sd0Prefix\.$Xfinity_Secure_24_VLANID"
                        if [ $? -eq 1 ]; then
                            echo_t "[RDKB_PLATFORM_ERROR] : $l2sd0Prefix.$Xfinity_Secure_24_VLANID is not created after Second Retry, no more retries !!!"
                        fi
                    else
                        echo_t "[RDKB_PLATFORM_ERROR] : $l2sd0Prefix.$Xfinity_Secure_24_VLANID created at First Retry itself"
                    fi
                else
                #RDKB-17221: In some rare devices we found though Xfinity secured ssid enabled, but it did'nt create the gre tunnels
                #but all secured SSIDs Vaps were up and system remained in this state for long not allowing clients to
                #connect
                    echo_t "[RDKB_PLATFORM_ERROR] :XfinityWifi: Secured SSID 2.4 is enabled but gre tunnels not present, restoring it"
                    t2CountNotify "SYS_ERROR_GRETunnel_restored"
                    rcount=1
                fi
            fi
            fi

            #Secured Xfinity 5
            if [ "$SECURED_5" = "true" ]; then
            grePresent=$(ifconfig -a | grep "$grePrefix\.$Xfinity_Secure_5_VLANID")
			if [ "x$ovs_enable" = "xtrue" ];then
				brPresent=$(ovs-vsctl show | grep "brlan5")
			else
				brPresent=$(brctl show | grep "brlan5")
			fi
            
            if [ "$grePresent" = "" ] || [ "$brPresent" = "" ]; then
                ifconfig | grep "$l2sd0Prefix\.$Xfinity_Secure_5_VLANID"
                if [ $? -eq 1 ]; then
                    echo_t "XfinityWifi is enabled Secured gre created, but $l2sd0Prefix.$Xfinity_Secure_5_VLANID interface is not created try creatig it"
                    sysevent set multinet_8-status stopped
                    $UTOPIA_PATH/service_multinet_exec multinet-start 8
                    ifconfig $l2sd0Prefix.$Xfinity_Secure_5_VLANID up
                    ifconfig | grep "$l2sd0Prefix\.$Xfinity_Secure_5_VLANID"
                    if [ $? -eq 1 ]; then
                        echo_t "$l2sd0Prefix.$Xfinity_Secure_5_VLANID is not created at First Retry, try again after 2 sec"
                        sleep 2
                        sysevent set multinet_8-status stopped
                        $UTOPIA_PATH/service_multinet_exec multinet-start 8
                        ifconfig $l2sd0Prefix.$Xfinity_Secure_5_VLANID up
                        ifconfig | grep "$l2sd0Prefix\.$Xfinity_Secure_5_VLANID"
                        if [ $? -eq 1 ]; then
                            echo_t "[RDKB_PLATFORM_ERROR] : $l2sd0Prefix.$Xfinity_Secure_5_VLANID is not created after Second Retry, no more retries !!!"
                        fi
                    else
                        echo_t "[RDKB_PLATFORM_ERROR] : $l2sd0Prefix.$Xfinity_Secure_5_VLANID created at First Retry itself"
                    fi
                else
                    echo_t "[RDKB_PLATFORM_ERROR] :XfinityWifi: Secured SSID 5GHz is enabled but gre tunnels not present, restoring it"
                    t2CountNotify "SYS_ERROR_GRETunnel_restored"
                    rcount=1
                fi
            fi
            fi

            #New Public hotspot
            PUBLIC_5=$(dmcli eRT getv Device.WiFi.SSID.16.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
            if [ "$PUBLIC_5" = "true" ]; then
            grePresent=$(ifconfig -a | grep "$grePrefix\.$Xfinity_Public_5_VLANID")
			if [ "x$ovs_enable" = "xtrue" ];then
				brPresent=$(ovs-vsctl show | grep "brpub")
			else
				brPresent=$(brctl show | grep "brpub")
			fi
            
            if [ "$grePresent" = "" ] || [ "$brPresent" = "" ]; then
                ifconfig | grep "$l2sd0Prefix\.$Xfinity_Public_5_VLANID"
                if [ $? -eq 1 ]; then
                    echo_t "XfinityWifi is enabled, but $l2sd0Prefix.$Xfinity_Public_5_VLANID interface is not created try creating it"

                    Interface=$(psmcli get dmsb.l2net.11.Members.WiFi)
                    if [ "$Interface" = "" ]; then
                        echo_t "PSM value(ath15) is missing for $l2sd0Prefix.$Xfinity_Public_5_VLANID"
                        psmcli set dmsb.l2net.11.Members.WiFi ath15
                    fi

                    sysevent set multinet_11-status stopped
                    $UTOPIA_PATH/service_multinet_exec multinet-start 11
                    ifconfig $l2sd0Prefix.$Xfinity_Public_5_VLANID up
                    ifconfig | grep "$l2sd0Prefix\.$Xfinity_Public_5_VLANID"
                    if [ $? -eq 1 ]; then
                        echo_t "$l2sd0Prefix.$Xfinity_Public_5_VLANID is not created at First Retry, try again after 2 sec"
                        sleep 2
                        sysevent set multinet_11-status stopped
                        $UTOPIA_PATH/service_multinet_exec multinet-start 11
                        ifconfig $l2sd0Prefix.$Xfinity_Public_5_VLANID up
                        ifconfig | grep "$l2sd0Prefix\.$Xfinity_Public_5_VLANID"
                        if [ $? -eq 1 ]; then
                            echo_t "[RDKB_PLATFORM_ERROR] : $l2sd0Prefix.$Xfinity_Public_5_VLANID is not created after Second Retry, no more retries !!!"
                        fi
                    else
                        echo_t "[RDKB_PLATFORM_ERROR] : $l2sd0Prefix.$Xfinity_Public_5_VLANID created at First Retry itself"
                    fi
                else
                    echo_t "[RDKB_PLATFORM_ERROR] :Public XfinityWifi:  SSID 5GHz is enabled but gre tunnels not present, restoring it"
                    t2CountNotify "SYS_ERROR_GRETunnel_restored"
                    rcount=1
                fi
              fi
              fi


            if [ $rcount -eq 1 ] ; then
                sh $UTOPIA_PATH/service_multinet/handle_gre.sh hotspotfd-tunnelEP recover
            fi
        fi  # [ "$WAN_TYPE" != "EPON" ] && [ "$HOTSPOT_ENABLE" = "true" ]
    ;;
    "TCCBR")
          if [ "$HOTSPOT_ENABLE" = "true" ]; then
            Radio_1=$(dmcli eRT getv Device.WiFi.Radio.1.Status| grep "value" | cut -f3 -d":" | cut -f2 -d" ")
            if [ "$Radio_1" = "Up" ]; then
                XOPEN_24=$(dmcli eRT getv Device.WiFi.SSID.5.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
                XSEC_24=$(dmcli eRT getv Device.WiFi.SSID.9.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
                open2=`wlctl -i wl0.2 bss`
                sec2=`wlctl -i wl0.4 bss`
                xcount=0

                if [ "$XOPEN_24" = "true" ]; then
                      if [ "$open2" = "down" ]; then
                           wlctl -i wl0.2 bss up
                           echo_t "[RDKB_PLATFORM_INFO] :XfinityWifi:  TCBR  SSID:5 2.4GHz restoring"
                           xcount=1
                      fi
                fi
                if [ "$XSEC_24" = "true" ]; then
                      if [ "$sec2" = "down" ]; then
                           wlctl -i wl0.4 bss up
                           echo_t "[RDKB_PLATFORM_INFO] :XfinityWifi:  TCBR SSID:9 2.4GHz restoring"
                           xcount=1
                      fi
                fi

                if [ $xcount -eq 1 ] ; then
                      echo_t "apply settings for Radio 1"
                      dmcli eRT setv Device.WiFi.Radio.1.X_CISCO_COM_ApplySetting bool true
                fi
            fi

            Radio_2=$(dmcli eRT getv Device.WiFi.Radio.2.Status| grep "value" | cut -f3 -d":" | cut -f2 -d" ")
            if [ "$Radio_2" = "Up" ]; then
                XOPEN_5=$(dmcli eRT getv Device.WiFi.SSID.6.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
                XSEC_5=$(dmcli eRT getv Device.WiFi.SSID.10.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
                XOPEN_16=$(dmcli eRT getv Device.WiFi.SSID.16.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")

                open5=`wlctl -i wl1.2 bss`
                sec5=`wlctl -i wl1.4 bss`
                open16=`wlctl -i wl1.7 bss`

                if [ "$XOPEN_5" = "true" ]; then
                      if [ "$open5" = "down" ]; then
                           wlctl -i wl1.2 bss up
                           echo_t "[RDKB_PLATFORM_INFO] :XfinityWifi:  TCBR SSID:6 5GHz restoring"
                           xcount=1
                      fi
                fi
                if [ "$XSEC_5" = "true" ]; then
                      if [ "$sec5" = "down" ]; then
                           wlctl -i wl1.4 bss up
                           echo_t "[RDKB_PLATFORM_INFO] :XfinityWifi:  TCBR SSID:10 5GHz restoring"
                           xcount=1
                      fi
                fi
                if [ "$XOPEN_16" = "true" ]; then
                      if [ "$open16" = "down" ]; then
                           wlctl -i wl1.7 bss up
                           echo_t "[RDKB_PLATFORM_INFO] :XfinityWifi:  TCBR SSID:16 5GHz restoring"
                           xcount=1
                      fi
                fi

                if [ $xcount -eq 1 ] ; then
                      echo_t "apply settings for Radio 2"
                      dmcli eRT setv Device.WiFi.Radio.2.X_CISCO_COM_ApplySetting bool true
                fi
            fi

         fi
    ;;
    "SYSTEMD")
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
        # TODO: move LIGHTTPD_PID BASE code with TCCBR,SYSTEMD code!
    ;;
    "TCCBR"|"SYSTEMD")
	#Ignoring for XLE, Ashlene, and XD4 models. lighttpd and webgui.sh are not avaialble in these boxes.
	if [ "$MODEL_NUM" = "WNXL11BWL" ] || [ "$MODEL_NUM" = "SE501" ] || [ "$MODEL_NUM" = "CVA601ZCOM" ]; then
            : # Do nothing
        else
            # Checking lighttpd PID
            LIGHTTPD_PID=$(busybox pidof lighttpd)
            WEBGUI_PID=$(ps | grep "webgui.sh" | grep -v "grep" | awk '{ print $1 }')
            if [ "$LIGHTTPD_PID" = "" ]; then
                if [ "$WEBGUI_PID" != "" ]; then
                    if [ -f /tmp/WEBGUI_"$WEBGUI_PID" ]; then
                        echo_t "WEBGUI is in hung state, restarting it"
                        kill -9 "$WEBGUI_PID"
                        rm /tmp/WEBGUI_*

                        isPortKilled=$(netstat -anp | grep "21515")
                        if [ "$isPortKilled" != "" ]; then
                            echo_t "Port 21515 is still alive. Killing processes associated to 21515"
                            fuser -k 21515/tcp
                        fi
                        rm /tmp/webgui.lock
                        sh /etc/webgui.sh
                    else
                        for f in /tmp/WEBGUI_*
                          do
                            if [ -f "$f" ]; then  #TODO: file test not needed since we just got list of filenames from shell?
                                rm "$f"
                            fi
                          done
                        touch /tmp/WEBGUI_"$WEBGUI_PID"
                        echo_t "WEBGUI is running with pid $WEBGUI_PID"
                    fi
                else
                    isPortKilled=$(netstat -anp | grep "21515")
                    if [ "$isPortKilled" != "" ]; then
                        echo_t "Port 21515 is still alive. Killing processes associated to 21515"
                        fuser -k 21515/tcp
                    fi
                    if [ -f "/tmp/wifi_initialized" ]; then
                        echo_t "RDKB_PROCESS_CRASHED : lighttpd is not running, restarting it"
                        t2CountNotify "SYS_SH_lighttpdCrash"
                        #lighttpd -f $LIGHTTPD_CONF
                    else
                        #if wifi is not initialized, still starting lighttpd to have gui access. Not a crash.
                        echo_t "WiFi is not initialized yet. Starting lighttpd for GUI access."
                    fi
                    rm /tmp/webgui.lock
                    sh /etc/webgui.sh
                fi
            fi
        fi
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
        _start_parodus_()
        {
            echo_t "RDKB_PROCESS_CRASHED : parodus process is not running, need restart"
            t2CountNotify "WIFI_SH_Parodus_restart"
            echo_t "Check parodusCmd.cmd in /tmp"
            if [ -e /tmp/parodusCmd.cmd ]; then
                echo_t "parodusCmd.cmd exists in tmp, but deleting it to recreate and fetch new values"
                rm -rf /tmp/parodusCmd.cmd
                #start parodus
                /usr/bin/parodusStart &
                echo_t "Started parodusStart in background"
            else
                echo_t "parodusCmd.cmd does not exist in tmp, trying to start parodus"
                /usr/bin/parodusStart &
            fi
        }
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
    ;;
esac

# Checking for parodus connection stuck issue
# Checking parodus PID
PARODUS_PID=$(busybox pidof parodus)
case $SELFHEAL_TYPE in
    "BASE")
        PARODUSSTART_PID=$(busybox pidof parodusStart)
        if [ "$PARODUS_PID" = "" ] && [ "$PARODUSSTART_PID" = "" ]; then
            _start_parodus_
            thisPARODUS_PID=""    # avoid executing 'already-running' code below
        fi
    ;;
    "TCCBR"|"SYSTEMD")
        thisPARODUS_PID="$PARODUS_PID"
    ;;
esac
if [ "$thisPARODUS_PID" != "" ]; then
    # parodus process is running,
    kill_parodus_msg=""
    # check if parodus is stuck in connecting
    if [ "$kill_parodus_msg" = "" ] && [ -f $PARCONNHEALTH_PATH ]; then
        wan_status=$(sysevent get wan-status)
        if [ "$wan_status" = "started" ]; then
            time_line=$(awk '/^\{START=[0-9\,]+\}$/' $PARCONNHEALTH_PATH)
        else
            time_line=""
        fi
        health_time_pair=$(echo "$time_line" | tr -d "}" | cut -d"=" -f2)
        if [ "$health_time_pair" != "" ]; then
            conn_start_time=$(echo "$health_time_pair" | cut -d"," -f1)
            conn_retry_time=$(echo "$health_time_pair" | cut -d"," -f2)
            echo_t "Parodus connecting time '$health_time_pair'"
            time_now=$(date +%s)
            time_now_val=$((time_now+0))
            time_limit=$((conn_retry_time+1800))
            if [ $time_now_val -ge $time_limit ]; then
                # parodus connection health file has a recorded
                # time stamp that is > 30 minutes old, seems parodus conn is stuck
                kill_parodus_msg="Parodus Connection TimeStamp Expired."
                t2CountNotify "SYS_ERROR_parodus_TimeStampExpired"
            fi
            time_limit=$((conn_start_time+900))
            if [ $time_now_val -ge $time_limit ]; then
                echo_t "Parodus connection lost since 15 minutes"
            fi
        fi
    fi
    if [ "$kill_parodus_msg" != "" ]; then
        case $SELFHEAL_TYPE in
            "BASE")
                ppid=$(busybox pidof parodus)
                if [ "$ppid" != "" ]; then
                    echo_t "$kill_parodus_msg Killing parodus process."
                    t2CountNotify "SYS_SH_Parodus_Killed"
                    # want to generate minidump for further analysis hence using signal 11
                    kill -11 "$ppid"
                    sleep 1
                fi
                _start_parodus_
            ;;
            "TCCBR"|"SYSTEMD")
                ppid=$(busybox pidof parodus)
                if [ "$ppid" != "" ]; then
                    echo "[$(getDateTime)] $kill_parodus_msg Killing parodus process."
                    t2CountNotify "SYS_SH_Parodus_Killed"
                    # want to generate minidump for further analysis hence using signal 11
                    systemctl kill --signal=11 parodus.service
                fi
            ;;
        esac
    fi
fi

#Implement selfheal mechanism for aker to restart aker process in selfheal window  in XB3 devices
case $SELFHEAL_TYPE in
    "BASE")
	# Checking Aker PID
	AKER_PID=$(busybox pidof aker)
	if [ -f "/etc/AKER_ENABLE" ] &&  [ "$AKER_PID" = "" ]; then
		echo_t "[RDKB_PROCESS_CRASHED] : aker process is not running need restart"
		t2CountNotify "SYS_SH_akerCrash"
		if [ ! -f  "/tmp/aker_cmd.cmd" ] ; then
			echo_t "aker_cmd.cmd don't exist in tmp, creating it."
			echo "/usr/bin/aker -p $PARODUS_URL -c $AKER_URL -w parcon -d /nvram/pcs.bin -f /nvram/pcs.bin.md5" > /tmp/aker_cmd.cmd
		fi
		aker_cmd=`cat /tmp/aker_cmd.cmd`
		$aker_cmd &
	fi
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
        # TODO: move DROPBEAR BASE code with TCCBR,SYSTEMD code!
        #Check dropbear is alive to do rsync/scp to/fro ATOM
        if [ "$ARM_INTERFACE_IP" != "" ]; then
            DROPBEAR_ENABLE=$(ps -w | grep "dropbear" | grep "$ARM_INTERFACE_IP")
            if [ "$DROPBEAR_ENABLE" = "" ]; then
                echo_t "RDKB_PROCESS_CRASHED : rsync_dropbear_process is not running, need restart"
                t2CountNotify "SYS_SH_Dropbear_restart"	
                DROPBEAR_PARAMS_1="/tmp/.dropbear/dropcfg1_tdt2"
                DROPBEAR_PARAMS_2="/tmp/.dropbear/dropcfg2_tdt2"
                if [ ! -d '/tmp/.dropbear' ]; then
                    mkdir -p /tmp/.dropbear
                fi
                if [ ! -f $DROPBEAR_PARAMS_1 ]; then
                    getConfigFile $DROPBEAR_PARAMS_1
                fi
                if [ ! -f $DROPBEAR_PARAMS_2 ]; then
                    getConfigFile $DROPBEAR_PARAMS_2
                fi
                dropbear -r $DROPBEAR_PARAMS_1 -r $DROPBEAR_PARAMS_2 -E -s -p $ARM_INTERFACE_IP:22 -P /var/run/dropbear_ipc.pid > /dev/null 2>&1
            fi
        fi
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
        # TODO: move LIGHTTPD_PID BASE code with TCCBR,SYSTEMD code!
        # Checking lighttpd PID
        LIGHTTPD_PID=$(busybox pidof lighttpd)
        WEBGUI_PID=$(ps | grep "webgui.sh" | grep -v "grep" | awk '{ print $1 }')
        if [ "$LIGHTTPD_PID" = "" ]; then
            if [ "$WEBGUI_PID" != "" ]; then
                if [ -f /tmp/WEBGUI_"$WEBGUI_PID" ]; then
                    echo_t "WEBGUI is in hung state, restarting it"
                    kill -9 "$WEBGUI_PID"
                    rm /tmp/WEBGUI_*

                    isPortKilled=$(netstat -anp | grep "21515")
                    if [ "$isPortKilled" != "" ]; then
                        echo_t "Port 21515 is still alive. Killing processes associated to 21515"
                        fuser -k 21515/tcp
                    fi
                    rm /tmp/webgui.lock
                    sh /etc/webgui.sh
                else
                    for f in /tmp/WEBGUI_*
                      do
                        if [ -f "$f" ]; then  #TODO: file test not needed since we just got list of filenames from shell?
                            rm "$f"
                        fi
                      done
                    touch /tmp/WEBGUI_"$WEBGUI_PID"
                    echo_t "WEBGUI is running with pid $WEBGUI_PID"
                fi
            else
                isPortKilled=$(netstat -anp | grep "21515")
                if [ "$isPortKilled" != "" ]; then
                    echo_t "Port 21515 is still alive. Killing processes associated to 21515"
                    fuser -k 21515/tcp
                fi

                echo_t "RDKB_PROCESS_CRASHED : lighttpd is not running, restarting it"
                t2CountNotify "SYS_SH_lighttpdCrash"
                #lighttpd -f $LIGHTTPD_CONF
                rm /tmp/webgui.lock
                sh /etc/webgui.sh
            fi
        fi
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
    ;;
esac
#upflowed INTCS-125.patch as part of RDKB-41505.
if [ "$MODEL_NUM" = "TG3482G" ] || [ "$MODEL_NUM" = "TG4482A" ]; then
        tail -n $DCM_TMP_LINES $DCM_LOGS > $DCM_LOGS_TMP
       if grep -q -e "RF_ERROR_RpcRegisterFail" ${DCM_LOGS_TMP}; then
               echo "[RDKB_SELFHEAL] : ERROR, RPC Management Server Failed Registering" >> "$SECCONSOLE_LOGS"
               echo "[RDKB_SELFHEAL] : Restarting RPC Management Server Service" >> "$SECCONSOLE_LOGS"
               systemctl restart systemd-rpc_management_srv_init-puma7.service
       fi
               rm -rf $DCM_LOGS_TMP
fi

if [ "$MODEL_NUM" = "PX5001" ] || [ "$MODEL_NUM" = "PX5001B" ] || [ "$MODEL_NUM" = "CGA4131COM" ]; then
    #Checking if acsd is running and whether acsd core is generated or not
    #Check the status if 2.4GHz Wifi Radio
    RADIO_DISBLD_2G=-1
    Radio_1=$(dmcli eRT getv Device.WiFi.Radio.1.Enable)
    RadioExecution_1=$(echo "$Radio_1" | grep "Execution succeed")
    if [ "$RadioExecution_1" != "" ]; then
        isDisabled_1=$(echo "$Radio_1" | grep "false")
        if [ "$isDisabled_1" != "" ]; then
            RADIO_DISBLD_2G=1
        fi
    fi
    RADIO_DISBLD_5G=-1
    Radio_2=$(dmcli eRT getv Device.WiFi.Radio.2.Enable)
    RadioExecution_2=$(echo "$Radio_2" | grep "Execution succeed")
    if [ "$RadioExecution_2" != "" ]; then
        isDisabled_2=$(echo "$Radio_2" | grep "false")
        if [ "$isDisabled_2" != "" ]; then
            RADIO_DISBLD_5G=1
        fi
    fi
    RADIO_STATUS_2G=-1
    Radio_sts_1=$(dmcli eRT getv Device.WiFi.Radio.1.Status)
    RadioExecution_sts_1=$(echo "$Radio_sts_1" | grep "Execution succeed")
    if [ "$RadioExecution_sts_1" != "" ]; then
        isDisabled_3=$(echo "$Radio_sts_1" | grep "Down")
        if [ "$isDisabled_3" != "" ]; then
            RADIO_STATUS_2G=1
        fi
    fi
    RADIO_STATUS_5G=-1
    Radio_sts_2=$(dmcli eRT getv Device.WiFi.Radio.2.Status)
    RadioExecution_sts_2=$(echo "$Radio_sts_2" | grep "Execution succeed")
    if [ "$RadioExecution_sts_2" != "" ]; then
        isDisabled_4=$(echo "$Radio_sts_2" | grep "Down")
        if [ "$isDisabled_4" != "" ]; then
            RADIO_STATUS_5G=1
        fi
    fi
    if [ $RADIO_DISBLD_2G -eq 1 ] && [ $RADIO_DISBLD_5G -eq 1 ]; then
        echo_t "[RDKB_SELFHEAL] : Radio's disabled, Skipping ACSD check"
    elif [ $RADIO_STATUS_2G -eq 1 ] && [ $RADIO_STATUS_5G -eq 1 ]; then
        echo_t "[RDKB_SELFHEAL] : Radio's status is down, Skipping ACSD check"
    else
        ACSD_PID=$(busybox pidof acsd)
        if [ "$ACSD_PID" = ""  ]; then
            echo_t "[ACSD_CRASH/RESTART] : ACSD is not running "
        fi
        ACSD_CORE=$(ls /tmp | grep "core.prog_acsd")
        if [ "$ACSD_CORE" != "" ]; then
            echo_t "[ACSD_CRASH/RESTART] : ACSD core has been generated inside /tmp :  $ACSD_CORE"
            ACSD_CORE_COUNT=$(ls /tmp | grep -c "core.prog_acsd")
            echo_t "[ACSD_CRASH/RESTART] : Number of ACSD cores created inside /tmp  are : $ACSD_CORE_COUNT"
        fi
    fi
fi

#Checking Wheteher any core is generated inside /tmp folder
CORE_TMP=$(ls /tmp | grep "core.")
if [ "$CORE_TMP" != "" ]; then
    echo_t "[PROCESS_CRASH] : core has been generated inside /tmp :  $CORE_TMP"
    if [ "$CORE_TMP" = "snmp_subagent.core.gz" ]; then
        t2CountNotify "SYS_ERROR_snmpSubagentcrash"
    fi
    CORE_COUNT=$(ls /tmp | grep -c "core.")
    echo_t "[PROCESS_CRASH] : Number of cores created inside /tmp are : $CORE_COUNT"
fi


# Checking syseventd PID
SYSEVENT_PID=$(busybox pidof syseventd)
if [ "$SYSEVENT_PID" = "" ]; then
    #Needs to avoid false alarm
    rebootCounter=$(syscfg get X_RDKCENTRAL-COM_LastRebootCounter)
    echo_t "[syseventd] Previous rebootCounter:$rebootCounter"

    if [ ! -f "$SyseventdCrashed"  ] && [ "$rebootCounter" != "1" ] ; then
        echo_t "[RDKB_PROCESS_CRASHED] : syseventd is crashed, need to reboot the device in maintanance window."
        t2CountNotify "SYS_ERROR_syseventdCrashed"
        touch $SyseventdCrashed
        case $SELFHEAL_TYPE in
            "BASE"|"SYSTEMD")
                echo_t "Setting Last reboot reason"
                dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootReason string Syseventd_crash
                dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootCounter int 1
            ;;
            "TCCBR")
            ;;
        esac
    fi
    rebootDeviceNeeded=1
fi


# If syseventd is in bad state, then reboot the device in Maintenance window
SYSEVENT_PING_CHECK="/tmp/sysevent_ping_check"
ping_value=$(sysevent ping)
Last_reboot_reason="`syscfg get X_RDKCENTRAL-COM_LastRebootReason`"
rebootCounter="`syscfg get X_RDKCENTRAL-COM_LastRebootCounter`"
if [ "$ping_value" != "SUCCESS" ] && [ "$SYSEVENT_PID" != "" ];then 
    echo_t "[RDKB_PROCESS_ERROR] : syseventd pid is $SYSEVENT_PID But Ping to syseventd failed..."

    if [ ! -f "$SYSEVENT_PING_CHECK" ]; then
        echo "0" > $SYSEVENT_PING_CHECK
    fi

    count="`cat $SYSEVENT_PING_CHECK`"
    if [[ $count -lt 3 ]]; then
        sysevent debug 0xFEECFEEC
        sysevent debug 0xFEEDFEED
        cp /var/log/syseventd.err /var/log/syseventd.out /rdklogs/logs
        count=$((count + 1))
        echo "$count" > $SYSEVENT_PING_CHECK
    fi

    # If sysevent ping didn't succeed for last 3 times, then reboot the device in Maintenance window
    #if rebootCounter is already 1 then skip the below block
    if [[ $count -ge 3 ]] && ( [ "$Last_reboot_reason" != "Syseventd_BadState" ] || [ "$rebootCounter" != "1" ] ); then
        echo_t "[RDKB_PROCESS_CRASHED] : syseventd is in bad state, need to reboot the device in maintanance window."
        t2CountNotify "SYS_ERROR_syseventdBadState"
        echo_t "Setting Last reboot reason"
        syscfg set X_RDKCENTRAL-COM_LastRebootReason "Syseventd_BadState"
        syscfg set X_RDKCENTRAL-COM_LastRebootCounter "1"
        rebootDeviceNeeded=1
    fi
else
    if [ -f "$SYSEVENT_PING_CHECK" ]
    then
        rm -rf $SYSEVENT_PING_CHECK
        #revoke the lastreboot reason and counter if it set by Syseventd_BadState
        if [ "$Last_reboot_reason" = "Syseventd_BadState" ] && [ "$rebootCounter" = "1" ]
        then
            echo_t "[RDKB_PROCESS_INFO] : Revoking the LastRebootReason from Syseventd_BadState as syseventd is operational now"
            syscfg set X_RDKCENTRAL-COM_LastRebootReason ""
            syscfg set X_RDKCENTRAL-COM_LastRebootCounter "0"
            rebootDeviceNeeded=0
        fi
    fi
fi

case $SELFHEAL_TYPE in
    "BASE")
        # Checking snmp master PID
        if [ "$BOX_TYPE" = "XB3" ]; then
            SNMP_MASTER_PID=$(busybox pidof snmp_agent_cm)
            if [ "$SNMP_MASTER_PID" = "" ] && [  ! -f "$SNMPMASTERCRASHED"  ]; then
                echo_t "[RDKB_PROCESS_CRASHED] : snmp_agent_cm process crashed"
                touch $SNMPMASTERCRASHED
            fi
        fi

        if [ -e /tmp/atom_ro ]; then
            reboot_needed_atom_ro=1
            rebootDeviceNeeded=1
        fi
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")

        #Checking Wheteher any core is generated inside /tmp folder
        CORE_TMP=$(ls /tmp | grep "core.")
        if [ "$CORE_TMP" != "" ]; then
            echo_t "[PROCESS_CRASH] : core has been generated inside /tmp :  $CORE_TMP"
            if [ "$CORE_TMP" = "snmp_subagent.core.gz" ]; then
                t2CountNotify "SYS_ERROR_snmpSubagentcrash"
            fi
            CORE_COUNT=$(ls /tmp | grep -c "core.")
            echo_t "[PROCESS_CRASH] : Number of cores created inside /tmp are : $CORE_COUNT"
        fi
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
    ;;
esac

# ARRIS XB6 => MODEL_NUM=TG3482G
# Tech CBR  => MODEL_NUM=CGA4131COM
# Tech xb6  => MODEL_NUM=CGM4140COM
# Tech XB7  => MODEL_NUM=CGM4331COM
# CMX  XB7  => MODEL_NUM=TG4482A
# Tech CBR2 => MODEL_NUM=CGA4332COM
# Tech XB8  => MODEL_NUM=CGM4981COM
# Vant XER5 => MODEL_NUM=VTER11QEL
# This critical processes checking is handled in selfheal_aggressive.sh for above platforms
# Ref: RDKB-25546
if [ "$MODEL_NUM" != "TG3482G" ] && [ "$MODEL_NUM" != "CGA4131COM" ] && [ "$MODEL_NUM" != "CGM4140COM" ] && [ "$MODEL_NUM" != "CGM4331COM" ] && [ "$MODEL_NUM" != "CGM4981COM" ] && [ "$MODEL_NUM" != "CGM601TCOM" ] && [ "$MODEL_NUM" != "CWA438TCOM" ] && [ "$MODEL_NUM" != "SG417DBCT" ] && [ "$MODEL_NUM" != "TG4482A" ] && [ "$MODEL_NUM" != "CGA4332COM" ] && [ "$MODEL_NUM" != "VTER11QEL" ]
then
case $SELFHEAL_TYPE in
    "BASE")
        # Checking whether brlan0 and l2sd0.100 are created properly , if not recreate it

        if [ "$WAN_TYPE" != "EPON" ]; then
            check_device_mode=$(dmcli eRT getv Device.X_CISCO_COM_DeviceControl.LanManagementEntry.1.LanMode)
            check_param_get_succeed=$(echo "$check_device_mode" | grep "Execution succeed")
            if [ ! -f /tmp/.router_reboot ]; then
                if [ "$check_param_get_succeed" != "" ]; then
                    check_device_in_router_mode=$(echo "$check_device_mode" | grep "router")
                    if [ "$check_device_in_router_mode" != "" ]; then
                        check_if_brlan0_created=$(ifconfig | grep "brlan0")
                        check_if_brlan0_up=$(ifconfig brlan0 | grep "UP")
                        check_if_brlan0_hasip=$(ifconfig brlan0 | grep "inet addr")
                        check_if_l2sd0_100_created=$(ifconfig | grep "l2sd0.100")
                        check_if_l2sd0_100_up=$(ifconfig l2sd0.100 | grep "UP" )
                        if [ "$check_if_brlan0_created" = "" ] || [ "$check_if_brlan0_up" = "" ] || [ "$check_if_brlan0_hasip" = "" ] || [ "$check_if_l2sd0_100_created" = "" ] || [ "$check_if_l2sd0_100_up" = "" ]; then
                            echo_t "[RDKB_PLATFORM_ERROR] : Either brlan0 or l2sd0.100 is not completely up, setting event to recreate vlan and brlan0 interface"
                            echo_t "[RDKB_SELFHEAL_BOOTUP] : brlan0 and l2sd0.100 o/p "
                            ifconfig brlan0;ifconfig l2sd0.100;							
                            if [ "x$ovs_enable" = "xtrue" ];then
                            	ovs-vsctl show
                            else
                            	brctl show
                            fi
                            logNetworkInfo

                            ipv4_status=$(sysevent get ipv4_4-status)
                            lan_status=$(sysevent get lan-status)

                            if [ "$lan_status" != "started" ]; then
                                if [ "$ipv4_status" = "" ] || [ "$ipv4_status" = "down" ]; then
                                    echo_t "[RDKB_SELFHEAL] : ipv4_4-status is not set or lan is not started, setting lan-start event"
                                    sysevent set lan-start
                                    sleep 60
				else
				    if [ "$check_if_brlan0_created" = "" ] && [ "$check_if_l2sd0_100_created" = "" ]; then
					/etc/utopia/registration.d/02_multinet restart
				    fi

				    sysevent set multinet-down 1
				    sleep 5
				    sysevent set multinet-up 1
				    sleep 30
                                fi
                            else
				if [ "$check_if_brlan0_created" = "" ] && [ "$check_if_l2sd0_100_created" = "" ]; then
				    /etc/utopia/registration.d/02_multinet restart
				fi

				sysevent set multinet-down 1
				sleep 5
				sysevent set multinet-up 1
				sleep 30
			    fi
                        fi

                    fi
                else
                    echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while fetching device mode "
                    t2CountNotify "SYS_ERROR_Error_fetching_devicemode"
                fi
            else
                rm -rf /tmp/.router_reboot
            fi

            # Checking whether brlan1 and l2sd0.101 interface are created properly
            if [ "$thisIS_BCI" != "yes" ]; then
                check_if_brlan1_created=$(ifconfig | grep "brlan1")
                check_if_brlan1_up=$(ifconfig brlan1 | grep "UP")
                check_if_brlan1_hasip=$(ifconfig brlan1 | grep "inet addr")
                check_if_l2sd0_101_created=$(ifconfig | grep "l2sd0.101")
                check_if_l2sd0_101_up=$(ifconfig l2sd0.101 | grep "UP" )

                if [ "$check_if_brlan1_created" = "" ] || [ "$check_if_brlan1_up" = "" ] || [ "$check_if_brlan1_hasip" = "" ] || [ "$check_if_l2sd0_101_created" = "" ] || [ "$check_if_l2sd0_101_up" = "" ]; then
                    echo_t "[RDKB_PLATFORM_ERROR] : Either brlan1 or l2sd0.101 is not completely up, setting event to recreate vlan and brlan1 interface"
                    echo_t "[RDKB_SELFHEAL_BOOTUP] : brlan1 and l2sd0.101 o/p "
                    ifconfig brlan1;ifconfig l2sd0.101; 
                    if [ "x$ovs_enable" = "xtrue" ];then
                    	ovs-vsctl show
                    else
                    	brctl show
                    fi
					
                    ipv5_status=$(sysevent get ipv4_5-status)
                    lan_l3net=$(sysevent get homesecurity_lan_l3net)

                    if [ "$lan_l3net" != "" ]; then
                        if [ "$ipv5_status" = "" ] || [ "$ipv5_status" = "down" ]; then
                            echo_t "[RDKB_SELFHEAL] : ipv5_4-status is not set , setting event to create homesecurity lan"
                            sysevent set ipv4-up $lan_l3net
                            sleep 60
			else
			    if [ "$check_if_brlan1_created" = "" ] && [ "$check_if_l2sd0_101_created" = "" ] ; then
				/etc/utopia/registration.d/02_multinet restart
			    fi
			    sysevent set multinet-down 2
			    sleep 5
			    sysevent set multinet-up 2
			    sleep 10
                        fi
                    else
			if [ "$check_if_brlan1_created" = "" ] && [ "$check_if_l2sd0_101_created" = "" ] ; then
			    /etc/utopia/registration.d/02_multinet restart
			fi

			sysevent set multinet-down 2
			sleep 5
			sysevent set multinet-up 2
			sleep 10
		    fi
                fi
            fi
        fi
    ;;
    "TCCBR")
        # Checking whether brlan0 created properly , if not recreate it
        lanSelfheal=$(sysevent get lan_selfheal)
        echo_t "[RDKB_SELFHEAL] : Value of lanSelfheal : $lanSelfheal"
        if [ ! -f /tmp/.router_reboot ]; then
            if [ "$lanSelfheal" != "done" ]; then
                check_device_mode=$(dmcli eRT getv Device.X_CISCO_COM_DeviceControl.LanManagementEntry.1.LanMode)
                check_param_get_succeed=$(echo "$check_device_mode" | grep "Execution succeed")
                if [ "$check_param_get_succeed" != "" ]; then
                    check_device_in_router_mode=$(echo "$check_device_mode" | grep "router")
                    if [ "$check_device_in_router_mode" != "" ]; then
                        check_if_brlan0_created=$(ifconfig | grep "brlan0")
                        check_if_brlan0_up=$(ifconfig brlan0 | grep "UP")
                        check_if_brlan0_hasip=$(ifconfig brlan0 | grep "inet addr")
                        if [ "$check_if_brlan0_created" = "" ] || [ "$check_if_brlan0_up" = "" ] || [ "$check_if_brlan0_hasip" = "" ]; then
                            echo_t "[RDKB_PLATFORM_ERROR] : brlan0 is not completely up, setting event to recreate brlan0 interface"
                            t2CountNotify "SYS_ERROR_brlan0_not_created"
                            logNetworkInfo

                            ipv4_status=$(sysevent get ipv4_4-status)
                            lan_status=$(sysevent get lan-status)

                            if [ "$lan_status" != "started" ]; then
                                if [ "$ipv4_status" = "" ] || [ "$ipv4_status" = "down" ]; then
                                    echo_t "[RDKB_SELFHEAL] : ipv4_4-status is not set or lan is not started, setting lan-start event"
                                    sysevent set lan-start
                                    sleep 30
				else
				    if [ "$check_if_brlan0_created" = "" ]; then
					/etc/utopia/registration.d/02_multinet restart
				    fi

				    sysevent set multinet-down 1
				    sleep 5
				    sysevent set multinet-up 1
				    sleep 30
                                fi
                            else

				if [ "$check_if_brlan0_created" = "" ]; then
				    /etc/utopia/registration.d/02_multinet restart
				fi

				sysevent set multinet-down 1
				sleep 5
				sysevent set multinet-up 1
				sleep 30
			    fi
                            sysevent set lan_selfheal "done"
                        fi

                    fi
                else
                    echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while fetching device mode "
                    t2CountNotify "SYS_ERROR_Error_fetching_devicemode"
                fi
            else
                echo_t "[RDKB_SELFHEAL] : brlan0 already restarted. Not restarting again"
                t2CountNotify "SYS_SH_brlan0_restarted"
                sysevent set lan_selfheal ""
            fi
        else
            rm -rf /tmp/.router_reboot
        fi
    ;;
    "SYSTEMD")
        if [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ] && [ "$BOX_TYPE" != "SR213" ] && [ "$BOX_TYPE" != "WNXL11BWL" ]; then
            # Checking whether brlan0 is created properly , if not recreate it
            lanSelfheal=$(sysevent get lan_selfheal)
            echo_t "[RDKB_SELFHEAL] : Value of lanSelfheal : $lanSelfheal"
            if [ ! -f /tmp/.router_reboot ]; then
                if [ "$lanSelfheal" != "done" ]; then
                    # Check device is in router mode
                    # Get from syscfg instead of dmcli for performance reasons
                    check_device_in_bridge_mode=$(syscfg get bridge_mode)
                    if [ "$check_device_in_bridge_mode" = "0" ]; then
                        check_if_brlan0_created=$(ifconfig | grep "brlan0")
                        check_if_brlan0_up=$(ifconfig brlan0 | grep "UP")
                        check_if_brlan0_hasip=$(ifconfig brlan0 | grep "inet addr")
                        if [ "$check_if_brlan0_created" = "" ] || [ "$check_if_brlan0_up" = "" ] || [ "$check_if_brlan0_hasip" = "" ]; then
                            echo_t "[RDKB_PLATFORM_ERROR] : brlan0 is not completely up, setting event to recreate vlan and brlan0 interface"
                            t2CountNotify "SYS_ERROR_brlan0_not_created"
                            logNetworkInfo

                            ipv4_status=$(sysevent get ipv4_4-status)
                            lan_status=$(sysevent get lan-status)

                            if [ "$lan_status" != "started" ]; then
                                if [ "$ipv4_status" = "" ] || [ "$ipv4_status" = "down" ]; then
                                    echo_t "[RDKB_SELFHEAL] : ipv4_4-status is not set or lan is not started, setting lan-start event"
                                    sysevent set lan-start
                                    sleep 30
				else
				    if [ "$check_if_brlan0_created" = "" ]; then
					/etc/utopia/registration.d/02_multinet restart
				    fi

				    sysevent set multinet-down 1
				    sleep 5
				    sysevent set multinet-up 1
				    sleep 30
                                fi
                            else

				if [ "$check_if_brlan0_created" = "" ]; then
				    /etc/utopia/registration.d/02_multinet restart
				fi

				sysevent set multinet-down 1
				sleep 5
				sysevent set multinet-up 1
				sleep 30
			    fi
                            sysevent set lan_selfheal "done"
                        fi

                    fi
                else
                    echo_t "[RDKB_SELFHEAL] : brlan0 already restarted. Not restarting again"
                    t2CountNotify "SYS_SH_brlan0_restarted"
                    sysevent set lan_selfheal ""
                fi
            else
                rm -rf /tmp/.router_reboot
            fi
            # Checking whether brlan1 interface is created properly
            l3netRestart=$(sysevent get l3net_selfheal)
            echo_t "[RDKB_SELFHEAL] : Value of l3net_selfheal : $l3netRestart"

            if [ "$MODEL_NUM" = "CVA601ZCOM" ]; then
                : #Do nothing for XD4
            elif [ "$MODEL_NUM" = "SCER11BEL" ] && [ "$HomeSecuritySupport" == "false" ]; then
                : #Do  nothing for XER10 and if HomeSecurity Feature disabled.
            elif [ "$MODEL_NUM" = "AYER21BEL" ] && [ "$HomeSecuritySupport" == "false" ]; then
                : #Do  nothing for XER2 and if HomeSecurity Feature disabled.
            elif [ "$l3netRestart" != "done" ]; then

                check_if_brlan1_created=$(ifconfig | grep "brlan1")
                check_if_brlan1_up=$(ifconfig brlan1 | grep "UP")
                check_if_brlan1_hasip=$(ifconfig brlan1 | grep "inet addr")

                if [ "$check_if_brlan1_created" = "" ] || [ "$check_if_brlan1_up" = "" ] || [ "$check_if_brlan1_hasip" = "" ]; then
                    echo_t "[RDKB_PLATFORM_ERROR] : brlan1 is not completely up, setting event to recreate vlan and brlan1 interface"

                    ipv5_status=$(sysevent get ipv4_5-status)
                    lan_l3net=$(sysevent get homesecurity_lan_l3net)

                    if [ "$lan_l3net" != "" ]; then
                        if [ "$ipv5_status" = "" ] || [ "$ipv5_status" = "down" ]; then
                            echo_t "[RDKB_SELFHEAL] : ipv5_4-status is not set , setting event to create homesecurity lan"
                            sysevent set ipv4-up $lan_l3net
                            sleep 30
			else
			    if [ "$check_if_brlan1_created" = "" ]; then
				/etc/utopia/registration.d/02_multinet restart
			    fi

			    sysevent set multinet-down 2
			    sleep 5
			    sysevent set multinet-up 2
			    sleep 10
                        fi
                    else

			if [ "$check_if_brlan1_created" = "" ]; then
			    /etc/utopia/registration.d/02_multinet restart
			fi

			sysevent set multinet-down 2
			sleep 5
			sysevent set multinet-up 2
			sleep 10
		    fi
                    sysevent set l3net_selfheal "done"
                fi
            else
                echo_t "[RDKB_SELFHEAL] : brlan1 already restarted. Not restarting again"
            fi

            # Test to make sure that if mesh is enabled the backhaul tunnels are attached to the bridges
            MESH_ENABLE=$(dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.Mesh.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
            if [ "$MESH_ENABLE" = "true" ]; then
                echo_t "[RDKB_SELFHEAL] : Mesh is enabled, test if tunnels are attached to bridges"
                t2CountNotify "WIFI_INFO_mesh_enabled"

                # Fetch mesh tunnels from the brlan0 bridge if they exist
                if [ "x$ovs_enable" = "xtrue" ];then
                    brctl0_ifaces=$(ovs-vsctl list-ifaces brlan0 | egrep "pgd")
                else
                    brctl0_ifaces=$(brctl show brlan0 | egrep "pgd")
                fi
                br0_ifaces=$(ifconfig | egrep "^pgd" | egrep "\.100" | awk '{print $1}')

                for ifn in $br0_ifaces
                  do
                    brFound="false"

                    for br in $brctl0_ifaces
                      do
                        if [ "$br" = "$ifn" ]; then
                            brFound="true"
                        fi
                      done
                    if [ "$brFound" = "false" ]; then
                        echo_t "[RDKB_SELFHEAL] : Mesh bridge $ifn missing, adding iface to brlan0"
                            if [ "x$bridgeUtilEnable" = "xtrue" || "x$ovs_enable" = "xtrue" ];then
                                echo_t "RDKB_SELFHEAL : Ovs is enabled, calling bridgeUtils to  add $ifn to brlan0  :"
                                /usr/bin/bridgeUtils add-port brlan0 $ifn;
                            else
                                brctl addif brlan0 $ifn;
                            fi 

                    fi
                  done

                # Fetch mesh tunnels from the brlan1 bridge if they exist
                if [ "$thisIS_BCI" != "yes" ]; then
                    if [ "x$ovs_enable" = "xtrue" ];then
                    	brctl1_ifaces=$(ovs-vsctl list-ifaces brlan1 | egrep "pgd")
                    else
                    	brctl1_ifaces=$(brctl show brlan1 | egrep "pgd")
                    fi
                    br1_ifaces=$(ifconfig | egrep "^pgd" | egrep "\.101" | awk '{print $1}')

                    for ifn in $br1_ifaces
                      do
                        brFound="false"

                        for br in $brctl1_ifaces
                          do
                            if [ "$br" = "$ifn" ]; then
                                brFound="true"
                            fi
                          done
                        if [ "$brFound" = "false" ]; then
                            echo_t "[RDKB_SELFHEAL] : Mesh bridge $ifn missing, adding iface to brlan1"
                            if [ "x$bridgeUtilEnable" = "xtrue" || "x$ovs_enable" = "xtrue" ];then
                                echo_t "RDKB_SELFHEAL : Ovs is enabled, calling bridgeUtils to  add $ifn to brlan1  :"
                                /usr/bin/bridgeUtils add-port brlan1 $ifn;
                            else
                                brctl addif brlan1 $ifn;
                            fi 
                        fi
                      done
                fi
            fi
        fi #Not HUB4 && SR300 && SE501 && SR213 && WNXL11BWL
    ;;
esac
fi

# RDKB-41671 - Check Radio Enable/disable and status(up/Down) too while checking SSID Status
Radio_5G_Enable_Check()
{
    radioenable_5=$(dmcli eRT getv Device.WiFi.Radio.2.Enable)
    isRadioExecutionSucceed_5=$(echo "$radioenable_5" | grep "Execution succeed")
    if [ "$isRadioExecutionSucceed_5" != "" ]; then
        isRadioEnabled_5=$(echo "$radioenable_5" | grep "false")
        if [ "$isRadioEnabled_5" != "" ]; then
            RADIO_DISBLD_5G=1
            echo_t "[RDKB_SELFHEAL] : 5G Radio(Radio 2) is Disabled"
        else
            echo_t "[RDKB_SELFHEAL] : 5G Radio(Radio 2) is Enabled"
            fi
    else
        echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 5G Radio status."
        echo "$radioenable_5"
    fi
}



#!!! TODO: merge this $SELFHEAL_TYPE block !!!
case $SELFHEAL_TYPE in
    "BASE")
        SSID_DISABLED=0
        RADIO_DISBLD_5G=0
        ssidEnable=$(dmcli eRT getv Device.WiFi.SSID.2.Enable)
        ssidExecution=$(echo "$ssidEnable" | grep "Execution succeed")
        if [ "$ssidExecution" != "" ]; then
            isEnabled=$(echo "$ssidEnable" | grep "false")
            if [ "$isEnabled" != "" ]; then
                SSID_DISABLED=1
                echo_t "[RDKB_SELFHEAL] : SSID 5GHZ is disabled"
                t2CountNotify "WIFI_INFO_5G_DISABLED"
            fi
        else
            destinationError=$(echo "$ssidEnable" | grep "Can't find destination component")
            if [ "$destinationError" != "" ]; then
                echo_t "[RDKB_PLATFORM_ERROR] : Parameter cannot be found on WiFi subsystem"
                t2CountNotify "WIFI_ERROR_WifiDmCliError"
            else
                echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 5G Enable"
                echo "$ssidEnable"
            fi
        fi
        Radio_5G_Enable_Check
    ;;
    "TCCBR")
        #Selfheal will run after 15mins of bootup, then by now the WIFI initialization must have
        #completed, so if still wifi_initilization not done, we have to recover the WIFI
        #Restart the WIFI if initialization is not done with in 15mins of poweron.
        if [ "$WiFi_Flag" = "false" ]; then
            SSID_DISABLED=0
            RADIO_DISBLD_5G=0
            if [ -f "/tmp/wifi_initialized" ]; then
                echo_t "[RDKB_SELFHEAL] : WiFi Initialization done"
                ssidEnable=$(dmcli eRT getv Device.WiFi.SSID.2.Enable)
                ssidExecution=$(echo "$ssidEnable" | grep "Execution succeed")
                if [ "$ssidExecution" != "" ]; then
                    isEnabled=$(echo "$ssidEnable" | grep "false")
                    if [ "$isEnabled" != "" ]; then
                        SSID_DISABLED=1
                        echo_t "[RDKB_SELFHEAL] : SSID 5GHZ is disabled"
                        t2CountNotify "WIFI_INFO_5G_DISABLED"
                    fi
                else
                    destinationError=$(echo "$ssidEnable" | grep "Can't find destination component")
                    if [ "$destinationError" != "" ]; then
                        echo_t "[RDKB_PLATFORM_ERROR] : Parameter cannot be found on WiFi subsystem"
                        t2CountNotify "WIFI_ERROR_WifiDmCliError"
                    else
                        echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 5G Enable"
                        echo "$ssidEnable"
                    fi
                fi
                Radio_5G_Enable_Check
            else
                echo_t  "[RDKB_PLATFORM_ERROR] : WiFi initialization not done"
                if [ -f "$thisREADYFILE" ]; then
                    echo_t  "[RDKB_PLATFORM_ERROR] : restarting the CcspWifiSsp"
                    killall CcspWifiSsp
                    resetNeeded wifi CcspWifiSsp
                fi
            fi
        fi
    ;;
    "SYSTEMD")
        #Selfheal will run after 15mins of bootup, then by now the WIFI initialization must have
        #completed, so if still wifi_initilization not done, we have to recover the WIFI
        #Restart the WIFI if initialization is not done with in 15mins of poweron.
        if [ "$WiFi_Flag" = "false" -a "$MODEL_NUM" != "CVA601ZCOM" ]; then
            SSID_DISABLED=0
            RADIO_DISBLD_5G=0
            if [ -f "/tmp/wifi_initialized" ]; then
                echo_t "[RDKB_SELFHEAL] : WiFi Initialization done"
                ssidEnable=$(dmcli eRT getv Device.WiFi.SSID.2.Enable)
                ssidExecution=$(echo "$ssidEnable" | grep "Execution succeed")
                if [ "$ssidExecution" != "" ]; then
                    isEnabled=$(echo "$ssidEnable" | grep "false")
                    if [ "$isEnabled" != "" ]; then
                        SSID_DISABLED=1
                        echo_t "[RDKB_SELFHEAL] : SSID 5GHZ is disabled"
			t2CountNotify "WIFI_INFO_5G_DISABLED"
                    fi
                else
                    destinationError=$(echo "$ssidEnable" | grep "Can't find destination component")
                    if [ "$destinationError" != "" ]; then
                        echo_t "[RDKB_PLATFORM_ERROR] : Parameter cannot be found on WiFi subsystem"
                        t2CountNotify "WIFI_ERROR_WifiDmCliError"
                    else
                        echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 5G Enable"
                        echo "$ssidEnable"
                    fi
                fi
                Radio_5G_Enable_Check
            else
                echo_t  "[RDKB_PLATFORM_ERROR] : WiFi initialization not done"
		if [ "$BOX_TYPE" = "XB6" ] && ( [ "$MANUFACTURE" = "Technicolor" ] || [ "$MANUFACTURE" = "Sercomm"] ); then
                    if [ -f "$thisREADYFILE" ]; then
                        echo_t  "[RDKB_PLATFORM_ERROR] : restarting the CcspWifiSsp"
                        systemctl stop ccspwifiagent
                        systemctl start ccspwifiagent
                    fi
                fi
            fi
        fi
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
        #check for PandM response
        bridgeMode=$(dmcli eRT getv Device.X_CISCO_COM_DeviceControl.LanManagementEntry.1.LanMode)
        bridgeSucceed=$(echo "$bridgeMode" | grep "Execution succeed")
        if [ "$bridgeSucceed" = "" ]; then
            echo_t "[RDKB_SELFHEAL_DEBUG] : bridge mode = $bridgeMode"
            serialNumber=$(dmcli eRT getv Device.DeviceInfo.SerialNumber)
            echo_t "[RDKB_SELFHEAL_DEBUG] : SerialNumber = $serialNumber"
            modelName=$(dmcli eRT getv Device.DeviceInfo.ModelName)
            echo_t "[RDKB_SELFHEAL_DEBUG] : modelName = $modelName"

            pandm_timeout=$(echo "$bridgeMode" | grep "CCSP_ERR_TIMEOUT")
            pandm_notexist=$(echo "$bridgeMode" | grep "CCSP_ERR_NOT_EXIST")
            pandm_notconnect=$(echo "$bridgeMode" | grep "CCSP_ERR_NOT_CONNECT")
            if [ "$pandm_timeout" != "" ] || [ "$pandm_notexist" != "" ] || [ "$pandm_notconnect" != "" ]; then
                echo_t "[RDKB_PLATFORM_ERROR] : pandm parameter timed out or failed to return"
                cr_query=$(dmcli eRT getv com.cisco.spvtg.ccsp.pam.Name)
                cr_timeout=$(echo "$cr_query" | grep "CCSP_ERR_TIMEOUT")
                cr_pam_notexist=$(echo "$cr_query" | grep "CCSP_ERR_NOT_EXIST")
                cr_pam_notconnect=$(echo "$cr_query" | grep "CCSP_ERR_NOT_CONNECT")
                if [ "$cr_timeout" != "" ] || [ "$cr_pam_notexist" != "" ] || [ "$cr_pam_notconnect" != "" ]; then
                    echo_t "[RDKB_PLATFORM_ERROR] : pandm process is not responding. Restarting it"
                    t2CountNotify "SYS_ERROR_PnM_Not_Responding"
                    PANDM_PID=$(busybox pidof CcspPandMSsp)
                    if [ "$PANDM_PID" != "" ]; then
                        kill -9 "$PANDM_PID"
                    fi
                    rm -rf /tmp/pam_initialized
                    resetNeeded pam CcspPandMSsp
                fi
            fi
        fi
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
    ;;
esac

numofRadios=0
if [ "$MODEL_NUM" != "CVA601ZCOM" ]; then                                                                                                                                                                              
    isnumofRadiosExec=$(dmcli eRT getv Device.WiFi.RadioNumberOfEntries |grep "Execution succeed")                                                                                                                     
    if [ "$isnumofRadiosExec" != "" ]; then                                                                                                                                                                            
        numofRadios=$(dmcli eRT getv Device.WiFi.RadioNumberOfEntries | grep value | awk '{ print $5 }')                                                                                                               
    else                                                                                                                                                                                                               
        echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking number of radios"                                                                                                                          
        echo "$isnumofRadiosExec"                                                                                                                                                                                      
    fi                                                                                                                                                                                                                 
fi

if [ $numofRadios -eq 3 ]; then
    SSID_DISABLED_6G=0
    ssidEnable_6=$(dmcli eRT getv Device.WiFi.SSID.17.Enable)
    ssidExecution_6=$(echo "$ssidEnable_6" | grep "Execution succeed")

    if [ "$ssidExecution_6" != "" ]; then
        isEnabled_6=$(echo "$ssidEnable_6" | grep "false")
        if [ "$isEnabled_6" != "" ]; then
            radioenable_6=$(dmcli eRT getv Device.WiFi.Radio.3.Enable)
            isRadioExecutionSucceed_6=$(echo "$radioenable_6" | grep "Execution succeed")
            if [ "$isRadioExecutionSucceed_6" != "" ]; then
                isRadioEnabled_6=$(echo "$radioenable_6" | grep "false")
                if [ "$isRadioEnabled_6" != "" ]; then
                    echo_t "[RDKB_SELFHEAL] : Both 6G Radio(Radio 3) and 6G Private SSID are in DISABLED state"
                else
                    echo_t "[RDKB_SELFHEAL] : 6G Radio(Radio 3) is Enabled, only 6G private SSID is DISABLED"
                fi
            else
                echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 6G Radio status."
                echo "$radioenable_6"
            fi
            SSID_DISABLED_6G=1
            echo_t "[RDKB_SELFHEAL] : SSID 6GHZ is disabled"
            t2CountNotify "WIFI_INFO_6G_DISABLED"
        fi
    else
        echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 6G Enable"
        echo "$ssidEnable_6"
    fi
fi

if ([ "$SELFHEAL_TYPE" = "BASE" ] || [ "$WiFi_Flag" = "false" ]) && [ "$MODEL_NUM" != "CVA601ZCOM" ]; then
    # If bridge mode is not set and WiFI is not disabled by user,
    # check the status of SSID
    if [ $BR_MODE -eq 0 ] && [ $SSID_DISABLED -eq 0 ] && [ $RADIO_DISBLD_5G -eq 0 ]; then
        ssidStatus_5=$(dmcli eRT getv Device.WiFi.SSID.2.Status)
        isExecutionSucceed=$(echo "$ssidStatus_5" | grep "Execution succeed")
        if [ "$isExecutionSucceed" != "" ]; then
            FILE_5G_HOSTAPD_RESTART_FLAG="/nvram/.restart_5G_hostapd_in_maintenace_window"

            isUp=$(echo "$ssidStatus_5" | grep "Up")
            if [ "$isUp" = "" ]; then
                # We need to verify if it was a dmcli crash or is WiFi really down
                isDown=$(echo "$ssidStatus_5" | grep "Down")
                if [ "$isDown" != "" ]; then
                    radioStatus_5=$(dmcli eRT getv Device.WiFi.Radio.2.Status)
                    isRadioExecutionSucceed_5=$(echo "$radioStatus_5" | grep "Execution succeed")
                    if [ "$isRadioExecutionSucceed_5" != "" ]; then
                        isRadioDown_5=$(echo "$radioStatus_5" | grep "Down")
                        if [ "$isRadioDown_5" != "" ]; then
                            echo_t "[RDKB_SELFHEAL] : Both 5G Radio(Radio 2) and 5G Private SSID are in DOWN state"
                        else
                            echo_t "[RDKB_SELFHEAL] : 5G Radio(Radio 2) is in up state, only 5G Private SSID is in DOWN state"
                            #### CMXB7-5392: 5G SSID disabled
                            if [[ "$MODEL_NUM" == "TG4482A" ]]; then
                                checkMaintenanceWindow
                                if [[ "$reb_window" == "1" ]]; then
                                    echo_t "[RDKB_SELFHEAL] : Restarting CcspWifiSsp now within maintenance window"
                                    systemctl restart ccspwifiagent.service
                                fi
                            fi
                            #### End of CMXB7-5392
                        fi

                            #### TCXB8-2214: 5G SSID down due to hostapd unresponsive
                            if [ "$MODEL_NUM" == "CGM4981COM" ] || [ "$MODEL_NUM" == "CGM601TCOM" ] || [ "$MODEL_NUM" == "CWA438TCOM" ] || [ "$MODEL_NUM" == "SG417DBCT" ]; then
                                buf=$(grep "5G hostapd is unresponsive" /rdklogs/logs/wifi_vendor_apps.log)
                                if [[ "$buf" != "" ]]; then
                                    echo_t "[RDKB_PLATFORM_ERROR] : 5G hostapd is unresponsive"
                                    if [ -f "$FILE_5G_HOSTAPD_RESTART_FLAG" ]; then
                                        echo "1" > "$FILE_5G_HOSTAPD_RESTART_FLAG"
                                    else
                                        echo "0" > "$FILE_5G_HOSTAPD_RESTART_FLAG"
                                    fi
                                else
                                    # The log of "5G hostapd is unresponsive" may have been uploaded; therefore, no longer available.
                                    # Perform the following only one time after detecting the SSID Status is Down
                                    if [ ! -f "$FILE_5G_HOSTAPD_RESTART_FLAG" ]; then
                                        echo "0" > "$FILE_5G_HOSTAPD_RESTART_FLAG"
                                    fi
                                fi
                                #### CBR2-1716 : 5G SSID down due to control interface setup failed for wl1
                                buf1=$(grep "Failed to setup control interface for wl1" /rdklogs/logs/wifi_vendor_apps.log)
                                if [[ "$buf1" != "" ]]; then
                                    echo_t "[RDKB_PLATFORM_ERROR] : Failed to setup control interface for wl1"
                                    if [ -f "$FILE_5G_HOSTAPD_RESTART_FLAG" ]; then
                                        echo "1" > "$FILE_5G_HOSTAPD_RESTART_FLAG"
                                    else
                                        echo "0" > "$FILE_5G_HOSTAPD_RESTART_FLAG"
                                    fi
                                else
                                    # The log of "Failed to setup control interface for wl1" may have been uploaded; therefore, no longer available.
                                    # Perform the following only one time after detecting the SSID Status is Down
                                    if [ ! -f "$FILE_5G_HOSTAPD_RESTART_FLAG" ]; then
                                        echo "0" > "$FILE_5G_HOSTAPD_RESTART_FLAG"
                                    fi
                                fi
                                #### End of CBR2-1716
                                if [ -f "$FILE_5G_HOSTAPD_RESTART_FLAG" ]; then
                                    count=$(head -n1 "$FILE_5G_HOSTAPD_RESTART_FLAG" | sed -e 's/^[^0-9]*\([0-9][0-9]*\).*/\1/')
                                    if [[ "$count" == "0" ]]; then
                                        echo_t "[RDKB_SELFHEAL] : Resetting 5G hostapd now right away"
                                        echo "1" > "$FILE_5G_HOSTAPD_RESTART_FLAG"
                                        /usr/bin/wifi_setup.sh restart 1    # 0-2G, 1-5G, 2-6G
                                    else
                                        checkMaintenanceWindow
                                        if [[ "$reb_window" == "1" ]]; then
                                            echo_t "[RDKB_SELFHEAL] : Resetting 5G hostapd now within maintenance window"
                                            /usr/bin/wifi_setup.sh restart 1    # 0-2G, 1-5G, 2-6G
                                        fi
                                    fi
                                fi
                            fi
                            #### End of TCXB8-2214
                    else
                        echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 5G Radio status."
                        echo "$radioStatus_5"
                    fi
                    echo_t "[RDKB_PLATFORM_ERROR] : 5G private SSID (ath1) is off."
                    t2CountNotify "WIFI_INFO_5GPrivateSSID_OFF"
                else
                    echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 5G status."
                    echo "$ssidStatus_5"
                fi
            else
                #### TCXB8-2214: 5G SSID down due to hostapd unresponsive
                # 5G SSID is up, remove the hostapd restart flag
                if [ "$MODEL_NUM" == "CGM4981COM" ] || [ "$MODEL_NUM" == "CGM601TCOM" ] || [ "$MODEL_NUM" == "CWA438TCOM" ] || [ "$MODEL_NUM" == "SG417DBCT" ] || [ "$MODEL_NUM" == "CGA4332COM" ]; then
                    if [ -f "$FILE_5G_HOSTAPD_RESTART_FLAG" ]; then
                        echo_t "[RDKB_SELFHEAL] : 5G Private SSID is now up, removing $FILE_5G_HOSTAPD_RESTART_FLAG"
                        rm "$FILE_5G_HOSTAPD_RESTART_FLAG"
                    fi
                fi
                #### End of TCXB8-2214
            fi
        else
            echo_t "[RDKB_PLATFORM_ERROR] : dmcli crashed or something went wrong while checking 5G status."
            t2CountNotify "WIFI_ERROR_DMCLI_crash_5G_Status"
            echo "$ssidStatus_5"
        fi
    fi

    # Check the status if 2.4GHz Wifi SSID
    SSID_DISABLED_2G=0
    RADIO_DISBLD_2G=0
    ssidEnable_2=$(dmcli eRT getv Device.WiFi.SSID.1.Enable)
    ssidExecution_2=$(echo "$ssidEnable_2" | grep "Execution succeed")

    if [ "$ssidExecution_2" != "" ]; then
        isEnabled_2=$(echo "$ssidEnable_2" | grep "false")
        if [ "$isEnabled_2" != "" ]; then
            SSID_DISABLED_2G=1
            echo_t "[RDKB_SELFHEAL] : SSID 2.4GHZ is disabled"
            t2CountNotify "WIFI_INFO_2G_DISABLED"
        fi
    else
        echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 2.4G Enable"
        echo "$ssidEnable_2"
    fi
    radioEnable_2=$(dmcli eRT getv Device.WiFi.Radio.1.Enable)
    radioExecution_2=$(echo "$radioEnable_2" | grep "Execution succeed")

    if [ "$radioExecution_2" != "" ]; then
        isRadioEnabled_2=$(echo "$radioEnable_2" | grep "false")
        if [ "$isRadioEnabled_2" != "" ]; then
            RADIO_DISBLD_2G=1
            echo_t "[RDKB_SELFHEAL] : 2G Radio(Radio 1) is Disabled"
        else
            echo_t "[RDKB_SELFHEAL] : 2G Radio(Radio 1) is Enabled"
        fi
        else
        echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 2.4G Radio Enable"
        echo $radioEnable_2
    fi

    # If bridge mode is not set and WiFI is not disabled by user,
    # check the status of SSID
    if [ $BR_MODE -eq 0 ] && [ $SSID_DISABLED_2G -eq 0 ] && [ $RADIO_DISBLD_2G -eq 0 ]; then
        ssidStatus_2=$(dmcli eRT getv Device.WiFi.SSID.1.Status)
        isExecutionSucceed_2=$(echo "$ssidStatus_2" | grep "Execution succeed")
        if [ "$isExecutionSucceed_2" != "" ]; then
            FILE_2G_HOSTAPD_RESTART_FLAG="/nvram/.restart_2G_hostapd_in_maintenace_window"

            isUp=$(echo "$ssidStatus_2" | grep "Up")
            if [ "$isUp" = "" ]; then
                # We need to verify if it was a dmcli crash or is WiFi really down
                isDown=$(echo "$ssidStatus_2" | grep "Down")
                if [ "$isDown" != "" ]; then
                    radioStatus_2=$(dmcli eRT getv Device.WiFi.Radio.1.Status)
                    isRadioExecutionSucceed_2=$(echo "$radioStatus_2" | grep "Execution succeed")
                    if [ "$isRadioExecutionSucceed_2" != "" ]; then
                        isRadioDown_2=$(echo "$radioStatus_2" | grep "Down")
                        if [ "$isRadioDown_2" != "" ]; then
                            echo_t "[RDKB_SELFHEAL] : Both 2G Radio(Radio 1) and 2G Private SSID are in DOWN state"
                        else
                            echo_t "[RDKB_SELFHEAL] : 2G Radio(Radio 1) is in up state, only 2G Private SSID is in DOWN state"
                           #### CMXB7-5473: 2G SSID disabled
                            if [[ "$MODEL_NUM" == "TG4482A" ]]; then
                                checkMaintenanceWindow
                                if [[ "$reb_window" == "1" ]]; then
                                    echo_t "[RDKB_SELFHEAL] : Restarting CcspWifiSsp now within maintenance window"
                                    systemctl restart ccspwifiagent.service
                                fi
                            fi
                            #### End of CMXB7-5473

                            #### TCXB8-2119: 2G SSID down due to hostapd unresponsive
                            if [ "$MODEL_NUM" == "CGM4981COM" ] || [ "$MODEL_NUM" == "CGM601TCOM" ] || [ "$MODEL_NUM" == "CWA438TCOM" ] || [ "$MODEL_NUM" == "SG417DBCT" ]; then
                                buf=$(grep "2G hostapd is unresponsive" /rdklogs/logs/wifi_vendor_apps.log)
                                if [[ "$buf" != "" ]]; then
                                    echo_t "[RDKB_PLATFORM_ERROR] : 2G hostapd is unresponsive"
                                    if [ -f "$FILE_2G_HOSTAPD_RESTART_FLAG" ]; then
                                        echo "1" > "$FILE_2G_HOSTAPD_RESTART_FLAG"
                                    else
                                        echo "0" > "$FILE_2G_HOSTAPD_RESTART_FLAG"
                                    fi
                                else
                                    #### TCXB8-2182 2G private SSID down but the log of "hostapd is unresponsive" may have been uploaded
                                    # Perform the following one time after detecting the interface is down
                                    if [ ! -f "$FILE_2G_HOSTAPD_RESTART_FLAG" ]; then
                                        echo "0" > "$FILE_2G_HOSTAPD_RESTART_FLAG"
                                    fi
                                    #### TCXB8-2182 2G private SSID down
                                fi
                                if [ -f "$FILE_2G_HOSTAPD_RESTART_FLAG" ]; then
                                    count=$(head -n1 "$FILE_2G_HOSTAPD_RESTART_FLAG" | sed -e 's/^[^0-9]*\([0-9][0-9]*\).*/\1/')
                                    if [[ "$count" == "0" ]]; then
                                        echo_t "[RDKB_SELFHEAL] : Resetting 2G hostapd now right away"
                                        echo "1" > "$FILE_2G_HOSTAPD_RESTART_FLAG"
                                        /usr/bin/wifi_setup.sh restart 0    # 0-2G, 1-5G, 2-6G
                                    else
                                        checkMaintenanceWindow
                                        if [[ "$reb_window" == "1" ]]; then
                                            echo_t "[RDKB_SELFHEAL] : Resetting 2G hostapd now within maintenance window"
                                            /usr/bin/wifi_setup.sh restart 0    # 0-2G, 1-5G, 2-6G
                                        fi
                                    fi
                                fi
                            fi
                            #### End of TCXB8-2119
                        fi
                    else
                        echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 2G Radio status."
                        echo "$radioStatus_2"
                    fi
                    echo_t "[RDKB_PLATFORM_ERROR] : 2.4G private SSID (ath0) is off."
                    t2CountNotify "WIFI_INFO_2GPrivateSSID_OFF"
                else
                    echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 2.4G status."
                    echo "$ssidStatus_2"
                fi
            else
                #### TCXB8-2119: 2G SSID down due to hostapd unresponsive
                # 2G SSID is up, remove the hostapd restart flag
                if [ "$MODEL_NUM" == "CGM4981COM" ] || [ "$MODEL_NUM" == "CGM601TCOM" ] || [ "$MODEL_NUM" == "CWA438TCOM" ] || [ "$MODEL_NUM" == "SG417DBCT" ]; then
                    if [ -f "$FILE_2G_HOSTAPD_RESTART_FLAG" ]; then
                        echo_t "[RDKB_SELFHEAL] : 2G Private SSID is now up, removing $FILE_2G_HOSTAPD_RESTART_FLAG"
                        rm "$FILE_2G_HOSTAPD_RESTART_FLAG"
                    fi
                fi
                #### End of TCXB8-2119
            fi
        else
            echo_t "[RDKB_PLATFORM_ERROR] : dmcli crashed or something went wrong while checking 2.4G status."
            t2CountNotify "WIFI_ERROR_DMCLI_crash_2G_Status"
            echo "$ssidStatus_2"
        fi
    fi
fi

FIREWALL_ENABLED=$(syscfg get firewall_enabled)

echo_t "[RDKB_SELFHEAL] : BRIDGE_MODE is $BR_MODE"
if [ $BR_MODE -eq 1 ]; then
    t2CountNotify "SYS_INFO_BridgeMode"
fi
echo_t "[RDKB_SELFHEAL] : FIREWALL_ENABLED is $FIREWALL_ENABLED"
if [ "$FIREWALL_ENABLED" = "" ] || [ $FIREWALL_ENABLED -ne 1 ]; then
   echo_t "[RDKB_PLATFORM_ERROR] : firewall_enabled corrupted in DB,enable and restart firewall."
   syscfg set firewall_enabled 1
   syscfg commit
   sysevent set firewall-restart
fi   

#Check whether private SSID's are broadcasting during bridge-mode or not
#if broadcasting then we need to disable that SSID's for pseduo mode(2)
#if device is in full bridge-mode(3) then we need to disable both radio and SSID's
if [ $BR_MODE -eq 1 -a "$MODEL_NUM" != "CVA601ZCOM" ]; then

    isBridging=$(syscfg get bridge_mode)
    echo_t "[RDKB_SELFHEAL] : BR_MODE:$isBridging"

    #full bridge-mode(3)
    if [ "$isBridging" = "3" ]; then
        # Check the status if 2.4GHz Wifi Radio
        RADIO_ENABLED_2G=0
        RadioEnable_2=$(dmcli eRT getv Device.WiFi.Radio.1.Enable)
        RadioExecution_2=$(echo "$RadioEnable_2" | grep "Execution succeed")

        if [ "$RadioExecution_2" != "" ]; then
            isEnabled_2=$(echo "$RadioEnable_2" | grep "true")
            if [ "$isEnabled_2" != "" ]; then
                RADIO_ENABLED_2G=1
                echo_t "[RDKB_SELFHEAL] : Radio 2.4GHZ is Enabled"
            fi
        else
            echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 2.4G radio Enable"
            echo "$RadioEnable_2"
        fi

        # Check the status if 5GHz Wifi Radio
        RADIO_ENABLED_5G=0
        RadioEnable_5=$(dmcli eRT getv Device.WiFi.Radio.2.Enable)
        RadioExecution_5=$(echo "$RadioEnable_5" | grep "Execution succeed")

        if [ "$RadioExecution_5" != "" ]; then
            isEnabled_5=$(echo "$RadioEnable_5" | grep "true")
            if [ "$isEnabled_5" != "" ]; then
                RADIO_ENABLED_5G=1
                echo_t "[RDKB_SELFHEAL] : Radio 5GHZ is Enabled"
            fi
        else
            echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 5G radio Enable"
            echo "$RadioEnable_5"
        fi

        if [ $numofRadios -eq 3 ]; then
            # Check the status if 6GHz Wifi Radio
            RADIO_ENABLED_6G=0
            RadioEnable_6=$(dmcli eRT getv Device.WiFi.Radio.3.Enable)
            RadioExecution_6=$(echo "$RadioEnable_5" | grep "Execution succeed")

            if [ "$RadioExecution_6" != "" ]; then
                isEnabled_6=$(echo "$RadioEnable_6" | grep "true")
                if [ "$isEnabled_6" != "" ]; then
                    RADIO_ENABLED_6G=1
                    echo_t "[RDKB_SELFHEAL] : Radio 6GHZ is Enabled"
                fi
            else
                echo_t "[RDKB_PLATFORM_ERROR] : Something went wrong while checking 6G radio Enable"
                echo "$RadioEnable_6"
            fi
        fi
        if [ $numofRadios -eq 3 ]; then
            if [ $RADIO_ENABLED_5G -eq 1 ] || [ $RADIO_ENABLED_2G -eq 1 ] || [ $RADIO_ENABLED_6G -eq 1 ]; then
                dmcli eRT setv Device.WiFi.Radio.1.Enable bool false
                sleep 2
                dmcli eRT setv Device.WiFi.Radio.2.Enable bool false
                sleep 2
                dmcli eRT setv Device.WiFi.Radio.3.Enable bool false
                sleep 2
                dmcli eRT setv Device.WiFi.SSID.3.Enable bool false
                sleep 2
                IsNeedtoDoApplySetting=1
            fi
        else
            if [ $RADIO_ENABLED_5G -eq 1 ] || [ $RADIO_ENABLED_2G -eq 1 ]; then
                dmcli eRT setv Device.WiFi.Radio.1.Enable bool false
                sleep 2
                dmcli eRT setv Device.WiFi.Radio.2.Enable bool false
                sleep 2
                dmcli eRT setv Device.WiFi.SSID.3.Enable bool false
                sleep 2
                IsNeedtoDoApplySetting=1
            fi
        fi
    fi

    if [ $numofRadios -eq 3 ]; then
        if [ $SSID_DISABLED_2G -eq 0 ] || [ $SSID_DISABLED -eq 0 ] || [ $SSID_DISABLED_6G -eq 0 ]; then
            dmcli eRT setv Device.WiFi.SSID.1.Enable bool false
            sleep 2
            dmcli eRT setv Device.WiFi.SSID.2.Enable bool false
            sleep 2
            dmcli eRT setv Device.WiFi.SSID.17.Enable bool false
            sleep 2
            IsNeedtoDoApplySetting=1
        fi
    else
        if [ $SSID_DISABLED_2G -eq 0 ] || [ $SSID_DISABLED -eq 0 ]; then
            dmcli eRT setv Device.WiFi.SSID.1.Enable bool false
            sleep 2
            dmcli eRT setv Device.WiFi.SSID.2.Enable bool false
            sleep 2
            IsNeedtoDoApplySetting=1
        fi
    fi

    if [ $numofRadios -eq 3 ]; then
        if [ "$IsNeedtoDoApplySetting" = "1" ]; then
            if systemctl status onewifi.service | grep active ; then
                dmcli eRT setv Device.WiFi.ApplyAccessPointSettings bool true
                sleep 3
                dmcli eRT setv Device.WiFi.ApplyRadioSettings bool true
            else
                dmcli eRT setv Device.WiFi.Radio.1.X_CISCO_COM_ApplySetting bool true
                sleep 3
                dmcli eRT setv Device.WiFi.Radio.2.X_CISCO_COM_ApplySetting bool true
                sleep 3
                dmcli eRT setv Device.WiFi.Radio.3.X_CISCO_COM_ApplySetting bool true
                sleep 3
                dmcli eRT setv Device.WiFi.X_CISCO_COM_ResetRadios bool true
            fi
        fi
    else
        if [ "$IsNeedtoDoApplySetting" = "1" ]; then
            if systemctl status onewifi.service | grep active ; then
                dmcli eRT setv Device.WiFi.ApplyAccessPointSettings bool true
                sleep 5
                dmcli eRT setv Device.WiFi.ApplyRadioSettings bool true
            else
                dmcli eRT setv Device.WiFi.Radio.1.X_CISCO_COM_ApplySetting bool true
                sleep 3
                dmcli eRT setv Device.WiFi.Radio.2.X_CISCO_COM_ApplySetting bool true
                sleep 3
                dmcli eRT setv Device.WiFi.X_CISCO_COM_ResetRadios bool true
            fi
        fi
    fi
fi

if [ $BR_MODE -eq 0 ]; then
    iptables-save -t nat | grep "A PREROUTING -i"
    if [ $? -eq 1 ]; then
        echo_t "[RDKB_PLATFORM_ERROR] : iptable corrupted."
        t2CountNotify "SYS_ERROR_iptable_corruption"
        #sysevent set firewall-restart
    fi
fi
if [ "$xle_device_mode" -eq "0" ]; then
    Ipv4_error_file="/tmp/.ipv4table_error"
    Ipv6_error_file="/tmp/.ipv6table_error"
elif [ "$xle_device_mode" -eq "1" ]; then
    Ipv4_error_file="/tmp/.ipv4table_ext_error"
    Ipv6_error_file="/tmp/.ipv6table_ext_error"
fi

if [ -s $Ipv4_error_file ] || [ -s $Ipv6_error_file ];then
    firewall_selfheal_count=$(sysevent get firewall_selfheal_count)
    if [ "$firewall_selfheal_count" = "" ];then
        firewall_selfheal_count=0
    fi
    if [ $firewall_selfheal_count -lt 3 ];then
        echo_t "[RDKB_SELFHEAL] : iptables error , restarting firewall"
        echo ">>>> $Ipv4_error_file <<<<"
        cat $Ipv4_error_file
        echo ">>>> $Ipv6_error_file <<<<"
        cat $Ipv6_error_file
        sysevent set firewall-restart
        firewall_selfheal_count=$((firewall_selfheal_count + 1))
        sysevent set firewall_selfheal_count $firewall_selfheal_count
        echo_t "[RDKB_SELFHEAL] : firewall_selfheal_count is $firewall_selfheal_count"
    else
        echo_t "[RDKB_SELFHEAL] : max firewall_selfheal_count reached, not restarting firewall"
    fi
fi

case $SELFHEAL_TYPE in
    "BASE"|"SYSTEMD")
        if [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ] && [ "$BOX_TYPE" != "SR213" ] && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ "$thisIS_BCI" != "yes" ] && [ $BR_MODE -eq 0 ] && [ ! -f "$brlan1_firewall" ]; then
            firewall_rules=$(iptables-save)
            check_if_brlan1=$(echo "$firewall_rules" | grep "brlan1")
            if [ "$check_if_brlan1" = "" ]; then
                echo_t "[RDKB_PLATFORM_ERROR]:brlan1_firewall_rules_missing,restarting firewall"
                sysevent set firewall-restart
            fi
            touch $brlan1_firewall
        fi
    ;;
    "TCCBR")
    ;;
esac

#Logging to check the DHCP range corruption
lan_ipaddr=$(syscfg get lan_ipaddr)
lan_netmask=$(syscfg get lan_netmask)
echo_t "[RDKB_SELFHEAL] [DHCPCORRUPT_TRACE] : lan_ipaddr = $lan_ipaddr lan_netmask = $lan_netmask"

lost_and_found_enable=$(syscfg get lost_and_found_enable)
echo_t "[RDKB_SELFHEAL] [DHCPCORRUPT_TRACE] :  lost_and_found_enable = $lost_and_found_enable"
if [ "$lost_and_found_enable" = "true" ]; then
    iot_ifname=$(syscfg get iot_ifname)
    if [ "$iot_ifname" = "l2sd0.106" ]; then
        iot_ifname=$(syscfg get iot_brname)
    fi
    iot_dhcp_start=$(syscfg get iot_dhcp_start)
    iot_dhcp_end=$(syscfg get iot_dhcp_end)
    iot_netmask=$(syscfg get iot_netmask)
    echo_t "[RDKB_SELFHEAL] [DHCPCORRUPT_TRACE] : DHCP server configuring for IOT iot_ifname = $iot_ifname "
    echo_t "[RDKB_SELFHEAL] [DHCPCORRUPT_TRACE] : iot_dhcp_start = $iot_dhcp_start iot_dhcp_end=$iot_dhcp_end iot_netmask=$iot_netmask"
fi

if [ "$xle_device_mode" -eq "0" ]; then
    #Checking whether dnsmasq is running or not and if zombie for XF3
    if [ "$thisWAN_TYPE" = "EPON" ]; then
        DNS_PID=$(busybox pidof dnsmasq)
        if [ "$DNS_PID" = "" ]; then
            InterfaceInConf=""
            Bridge_Mode_t=$(syscfg get bridge_mode)
            InterfaceInConf=$(grep "interface=" /var/dnsmasq.conf)
            if [ "$InterfaceInConf" = "" ] && [ "0" != "$Bridge_Mode_t" ] ; then
                if [ ! -f /tmp/dnsmaq_noiface ]; then
                    echo_t "[RDKB_SELFHEAL] : Unit in bridge mode,interface info not available in dnsmasq.conf"
                    touch /tmp/dnsmaq_noiface
                fi
            else
                echo_t "[RDKB_SELFHEAL] : dnsmasq is not running"
                t2CountNotify "SYS_SH_dnsmasq_restart"
            fi
        else
            if [ -f /tmp/dnsmaq_noiface ]; then
                rm -rf /tmp/dnsmaq_noiface
            fi
        fi
fi
    # ARRIS XB6 => MODEL_NUM=TG3482G
    # Tech CBR  => MODEL_NUM=CGA4131COM
    # Tech xb6  => MODEL_NUM=CGM4140COM
    # Tech XB7  => MODEL_NUM=CGM4331COM
    # CMX  XB7  => MODEL_NUM=TG4482A
    # Tech CBR2 => MODEL_NUM=CGA4332COM
    # Tech XB8  => MODEL_NUM=CGM4981COM
    # Vant XER5 => MODEL_NUM=VTER11QEL
    # This critical processes checking is handled in selfheal_aggressive.sh for above platforms
    # Ref: RDKB-25546
    if [ "$MODEL_NUM" != "TG3482G" ] && [ "$MODEL_NUM" != "CGA4131COM" ] &&
	   [ "$MODEL_NUM" != "CGM4140COM" ] && [ "$MODEL_NUM" != "CGM4331COM" ] && [ "$MODEL_NUM" != "CGM4981COM" ] && [ "$MODEL_NUM" != "CGM601TCOM" ] && [ "$MODEL_NUM" != "CWA438TCOM" ] && [ "$MODEL_NUM" != "SG417DBCT" ] && [ "$MODEL_NUM" != "TG4482A" ] && [ "$MODEL_NUM" != "CGA4332COM" ] && [ "$MODEL_NUM" != "VTER11QEL" ]
    then
    checkIfDnsmasqIsZombie=$(ps | grep "dnsmasq" | grep "Z" | awk '{ print $1 }')
    if [ "$checkIfDnsmasqIsZombie" != "" ] ; then
        for zombiepid in $checkIfDnsmasqIsZombie
          do
            confirmZombie=$(grep "State:" /proc/$zombiepid/status | grep -i "zombie")
            if [ "$confirmZombie" != "" ] ; then
                case $SELFHEAL_TYPE in
                    "BASE")
                    ;;
                    "TCCBR")
                    ;;
                    "SYSTEMD")
                        echo_t "[RDKB_SELFHEAL] : Zombie instance of dnsmasq is present, stopping CcspXdns"
                        t2CountNotify "SYS_ERROR_Zombie_dnsmasq"
                        systemctl stop CcspXdnsSsp.service
                    ;;
                esac
                echo_t "[RDKB_SELFHEAL] : Zombie instance of dnsmasq is present, restarting dnsmasq"
                t2CountNotify "SYS_ERROR_Zombie_dnsmasq"
                kill -9 $(busybox pidof dnsmasq)
                systemctl stop dnsmasq
                systemctl start dnsmasq
                if [ "$MODEL_NUM" = "SR213" ] || [ "$MODEL_NUM" = "SR203" ]; then
                        echo_t "[RDKB_SELFHEAL] : restarting dnsmasq"
                        sysevent set dhcp_server-restart
                fi
                case $SELFHEAL_TYPE in
                    "BASE")
                    ;;
                    "TCCBR")
                    ;;
                    "SYSTEMD")
                        echo_t "[RDKB_SELFHEAL] : Zombie instance of dnsmasq is present, restarting CcspXdns"
                        t2CountNotify "SYS_ERROR_Zombie_dnsmasq"
                        systemctl start CcspXdnsSsp.service
                    ;;
                esac
                break
            fi
          done
    fi
    fi
fi

#Checking whether dnsmasq is running or not
if [ "$thisWAN_TYPE" != "EPON" ]; then
    if [ "$xle_device_mode" -ne "1" ]; then
        DNS_PID=$(busybox pidof dnsmasq)
        if [ "$DNS_PID" = "" ]; then
            InterfaceInConf=""
            Bridge_Mode_t=$(syscfg get bridge_mode)
            InterfaceInConf=$(grep "interface=" /var/dnsmasq.conf)
            if [ "$InterfaceInConf" = "" ] && [ "0" != "$Bridge_Mode_t" ] ; then
                if [ ! -f /tmp/dnsmaq_noiface ]; then
                    echo_t "[RDKB_SELFHEAL] : Unit in bridge mode,interface info not available in dnsmasq.conf"
                    touch /tmp/dnsmaq_noiface
                fi
            else
                if [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ] && [ "$BOX_TYPE" != "SR213" ] && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ "$MODEL_NUM" != "CVA601ZCOM" ]; then
                    echo_t "[RDKB_SELFHEAL] : dnsmasq is not running"
                    t2CountNotify "SYS_SH_dnsmasq_restart"
                fi
            fi
        else
                brlan0up=$(grep "brlan0" /var/dnsmasq.conf)
                case $SELFHEAL_TYPE in
                    "BASE")
                        brlan1up=$(grep "brlan1" /var/dnsmasq.conf)
                        lnf_ifname=$(syscfg get iot_ifname)
                        if [ "$lnf_ifname" = "l2sd0.106" ]; then
                            lnf_ifname=$(syscfg get iot_brname)
                        fi
                        if [ "$lnf_ifname" != "" ]; then
                            echo_t "[RDKB_SELFHEAL] : LnF interface is: $lnf_ifname"
                            infup=$(grep "$lnf_ifname" /var/dnsmasq.conf)
                        else
                            echo_t "[RDKB_SELFHEAL] : LnF interface not available in DB"
                            #Set some value so that dnsmasq won't restart
                            infup="NA"
                        fi
                    ;;
                    "TCCBR")
                    ;;
                    "SYSTEMD")
                        brlan1up=$(grep "brlan1" /var/dnsmasq.conf)
                    ;;
                esac

        if [ -f /tmp/dnsmaq_noiface ]; then
            rm -rf /tmp/dnsmaq_noiface
        fi
        IsAnyOneInfFailtoUp=0

        if [ $BR_MODE -eq 0 ]; then
            if [ "$brlan0up" = "" ]; then
                echo_t "[RDKB_SELFHEAL] : brlan0 info is not availble in dnsmasq.conf"
                IsAnyOneInfFailtoUp=1
            fi
        fi

        case $SELFHEAL_TYPE in
            "BASE"|"SYSTEMD")
                if [ "$thisIS_BCI" != "yes" ] && [ "$brlan1up" = "" ] && [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ] && [ "$BOX_TYPE" != "SR213" ] && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ "$MODEL_NUM" != "CGA4332COM" ]; then
                    echo_t "[RDKB_SELFHEAL] : brlan1 info is not availble in dnsmasq.conf"
                    IsAnyOneInfFailtoUp=1
                fi
            ;;
            "TCCBR")
            ;;
        esac

        case $SELFHEAL_TYPE in
            "BASE")
                if [ "$infup" = "" ]; then
                    echo_t "[RDKB_SELFHEAL] : $lnf_ifname info is not availble in dnsmasq.conf"
                    IsAnyOneInfFailtoUp=1
                fi
            ;;
            "TCCBR")
            ;;
            "SYSTEMD")
            ;;
        esac

        if [ ! -f /tmp/dnsmasq_restarted_via_selfheal ]; then
            if [ $IsAnyOneInfFailtoUp -eq 1 ]; then
                touch /tmp/dnsmasq_restarted_via_selfheal

                echo_t "[RDKB_SELFHEAL] : dnsmasq.conf is."
                cat /var/dnsmasq.conf

                echo_t "[RDKB_SELFHEAL] : Setting an event to restart dnsmasq"
                sysevent set dhcp_server-restart
            fi
        fi

        case $SELFHEAL_TYPE in
            "BASE"|"SYSTEMD"|"TCCBR")
		# ARRIS XB6 => MODEL_NUM=TG3482G
		# Tech CBR  => MODEL_NUM=CGA4131COM
		# Tech xb6  => MODEL_NUM=CGM4140COM
		# Tech XB7  => MODEL_NUM=CGM4331COM
		# Tech CBR2 => MODEL_NUM=CGA4332COM
		# CMX  XB7  => MODEL_NUM=TG4482A
                # Tech XB8  => MODEL_NUM=CGM4981COM
		# Vant XER5 => MODEL_NUM=VTER11QEL
		# This critical processes checking is handled in selfheal_aggressive.sh for above platforms
		# Ref: RDKB-25546
		if [ "$MODEL_NUM" != "TG3482G" ] && [ "$MODEL_NUM" != "CGA4131COM" ] &&
		       [ "$MODEL_NUM" != "CGM4140COM" ] && [ "$MODEL_NUM" != "CGM4331COM" ] && [ "$MODEL_NUM" != "CGM4981COM" ] && [ "$MODEL_NUM" != "CGM601TCOM" ] && [ "$MODEL_NUM" != "CWA438TCOM" ] && [ "$MODEL_NUM" != "SG417DBCT" ] && [ "$MODEL_NUM" != "TG4482A" ] && [ "$MODEL_NUM" != "CGA4332COM" ] && [ "$MODEL_NUM" != "VTER11QEL" ]
		then
                checkIfDnsmasqIsZombie=$(ps | grep "dnsmasq" | grep "Z" | awk '{ print $1 }')
                if [ "$checkIfDnsmasqIsZombie" != "" ] ; then
                    for zombiepid in $checkIfDnsmasqIsZombie
                      do
                        confirmZombie=$(grep "State:" /proc/$zombiepid/status | grep -i "zombie")
                        if [ "$confirmZombie" != "" ] ; then
                            if [ "$SELFHEAL_TYPE" = "SYSTEMD" ] ; then
                                echo_t "[RDKB_SELFHEAL] : Zombie instance of dnsmasq is present, stopping CcspXdns"
                                systemctl stop CcspXdnsSsp.service
                            fi
                            echo_t "[RDKB_SELFHEAL] : Zombie instance of dnsmasq is present, restarting dnsmasq"
                            t2CountNotify "SYS_ERROR_Zombie_dnsmasq"
                            kill -9 $(busybox pidof dnsmasq)
                            sysevent set dhcp_server-restart
                            if [ "$SELFHEAL_TYPE" = "SYSTEMD" ] ; then
                                echo_t "[RDKB_SELFHEAL] : Zombie instance of dnsmasq is present, restarting CcspXdns"
                                systemctl start CcspXdnsSsp.service
                            fi
                            break
                        fi
                      done
                fi
		fi
            ;;
        esac
        fi # [ "$DNS_PID" = "" ]
    fi
fi  # [ "$thisWAN_TYPE" != "EPON" ]

case $SELFHEAL_TYPE in
    "BASE")
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
        #Checking ipv6 dad failure and restart dibbler client [TCXB6-5169]
    if [ "$BOX_TYPE" != "SE501" ] && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ "$DHCPcMonitoring" != "false" ]; then
        CHKIPV6_DAD_FAILED=$(ip -6 addr show dev $WAN_INTERFACE | grep "scope link tentative dadfailed")
        if [ "$CHKIPV6_DAD_FAILED" != "" ]; then
            echo_t "link Local DAD failed"
            t2CountNotify "SYS_ERROR_linkLocalDad_failed"
	    if [ "$BOX_TYPE" = "XB6" ] && ( [ "$MANUFACTURE" = "Technicolor" ] || [ "$MANUFACTURE" = "Sercomm" ] ); then
                partner_id=$(syscfg get PartnerID)
                if [ "$partner_id" != "comcast" ]; then
                    dibbler-client stop
                    sysctl -w net.ipv6.conf.$WAN_INTERFACE.disable_ipv6=1
                    sysctl -w net.ipv6.conf.$WAN_INTERFACE.accept_dad=0
                    sysctl -w net.ipv6.conf.$WAN_INTERFACE.disable_ipv6=0
                    sysctl -w net.ipv6.conf.$WAN_INTERFACE.accept_dad=1
                    dibbler-client start
                    echo_t "IPV6_DAD_FAILURE : successfully recovered for partner id $partner_id"
                    t2ValNotify "dadrecoverypartner_split" "$partner_id"
                fi
            fi
        fi
    fi
    ;;
esac

case $SELFHEAL_TYPE in
    "BASE")
    ;;
    "SYSTEMD")
        if [ "$BOX_TYPE" = "HUB4" ]; then
            WANMANAGER_REBOOT=$(sysevent get wanmanager_reboot_status)
            if [ "$WANMANAGER_REBOOT" = "1" ]; then
                echo_t "RDKB_SELFHEAL : wanmanager hw reconfiguration required , rebooting the device"
                t2CountNotify "SYS_INFO_WanManager_HW_reconfigure_reboot"
                reason="wanmanager_hw_reconfig"
                rebootCount=1
                rebootNeeded RM "WANMANAGER" $reason $rebootCount
            fi
        fi
    ;;
esac

# ARRIS XB6 => MODEL_NUM=TG3482G
# Tech CBR  => MODEL_NUM=CGA4131COM
# Tech xb6  => MODEL_NUM=CGM4140COM
# Tech XB7  => MODEL_NUM=CGM4331COM
# Tech CBR2 => MODEL_NUM=CGA4332COM
# CMX  XB7  => MODEL_NUM=TG4482A
# Tech XB8  => MODEL_NUM=CGM4981COM
# Vant XER5 => MODEL_NUM=VTER11QEL
# This critical processes checking is handled in selfheal_aggressive.sh for above platforms
# Ref: RDKB-25546
if [ "$xle_device_mode" -ne "1" ]; then
# for xle no need to check dibbler client and server
    if [ "$MODEL_NUM" != "TG3482G" ] && [ "$MODEL_NUM" != "CGA4131COM" ] &&
        [ "$MODEL_NUM" != "CGM4140COM" ] && [ "$MODEL_NUM" != "CGM4331COM" ] && [ "$MODEL_NUM" != "CGM4981COM" ] && [ "$MODEL_NUM" != "CGM601TCOM" ] && [ "$MODEL_NUM" != "CWA438TCOM" ] && [ "$MODEL_NUM" != "SG417DBCT" ] && [ "$MODEL_NUM" != "TG4482A" ] && [ "$MODEL_NUM" != "CGA4332COM" ] && [ "$MODEL_NUM" != "VTER11QEL" ]
    then
    #Checking dibbler server is running or not RDKB_10683
    DIBBLER_PID=$(busybox pidof dibbler-server)
    if [ "$DIBBLER_PID" = "" ]; then
    #   IPV6_STATUS=`sysevent get ipv6-status`
        if [ -f /tmp/dhcpmgr_initialized ]; then
            is_dhcpv6c_enabled
        else
            DHCPV6C_ENABLED=$(sysevent get dhcpv6c_enabled)
        fi
        routerMode="`syscfg get last_erouter_mode`"

    if [ "$BOX_TYPE" = "HUB4" ]; then
        #Since dibbler client not supported for hub4
        DHCPV6C_ENABLED="1"
    fi

    if [ "$BR_MODE" = "0" ] && [ "$DHCPV6C_ENABLED" = "1" ]; then
        Sizeof_ServerConf=`stat -c %s $DIBBLER_SERVER_CONF`
        DHCPv6_ServerType="`syscfg get dhcpv6s00::servertype`"
        case $SELFHEAL_TYPE in
            "BASE"|"TCCBR")
                DHCPv6EnableStatus=$(syscfg get dhcpv6s00::serverenable)
                if [ "$IS_BCI" = "yes" ] && [ "0" = "$DHCPv6EnableStatus" ]; then
                    echo_t "DHCPv6 Disabled. Restart of Dibbler process not Required"
                elif [ "$routerMode" = "1" ] || [ "$routerMode" = "" ] || [ "$Unit_Activated" = "0" ]; then
                        #TCCBR-4398 erouter0 not getting IPV6 prefix address from CMTS so as brlan0 also not getting IPV6 address.So unable to start dibbler service.
                        echo_t "DIBBLER : Non IPv6 mode dibbler server.conf file not present"
                else
                    if [ "$DHCPv6_ServerType" -ne 2 ] || [ "$BOX_TYPE" = "HUB4" ] || [ "$BOX_TYPE" = "SR300" ];then
                        echo_t "RDKB_PROCESS_CRASHED : Dibbler is not running, restarting the dibbler"
                        t2CountNotify "SYS_SH_Dibbler_restart"
                    fi
                    if [ -f "/etc/dibbler/server.conf" ]; then
                        BRLAN_CHKIPV6_DAD_FAILED=$(ip -6 addr show dev $PRIVATE_LAN | grep "scope link tentative dadfailed")
                        if [ "$BRLAN_CHKIPV6_DAD_FAILED" != "" ]; then
                            echo "DADFAILED : BRLAN0_DADFAILED"
                            t2CountNotify "SYS_ERROR_Dibbler_DAD_failed"


                            if [ "$BOX_TYPE" = "TCCBR" ]; then
                                echo "DADFAILED : Recovering device from DADFAILED state"
                                echo "1" > /proc/sys/net/ipv6/conf/$PRIVATE_LAN/disable_ipv6
                                sleep 1
                                echo "0" > /proc/sys/net/ipv6/conf/$PRIVATE_LAN/disable_ipv6
                                sleep 1
                                Dhcpv6_Client_restart "dibbler-client" "Idle"
                            fi
                        elif [ $Sizeof_ServerConf -le 1 ]; then
                            Dhcpv6_Client_restart "$DHCPv6_TYPE" "restart_for_dibbler-server"
                            ret_val=`echo $?`
                            if [ "$ret_val" = "1" ];then
                                echo "DIBBLER : Dibbler Server Config is empty"
                                t2CountNotify "SYS_ERROR_DibblerServer_emptyconf"
                            fi
                        elif [ "$DHCPv6_ServerType" -eq 2 ] && [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ]  && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ "$BOX_TYPE" != "SR213" ];  then
                            #if servertype is stateless(1-stateful,2-stateless),the ip assignment will be done through zebra process.Hence dibbler-server won't required.
                            echo_t "DHCPv6 servertype is stateless,dibbler-server restart not required"
                        else
                            dibbler-server stop
                            sleep 2
                            dibbler-server start
                        fi
                    else
                        echo_t "RDKB_PROCESS_CRASHED : dibbler server.conf file not present"
                        Dhcpv6_Client_restart "$DHCPv6_TYPE" "restart_for_dibbler-server"
                        ret_val=`echo $?`
                        if [ "$ret_val" = "2" ];then
                            echo_t "DIBBLER : Restart of dibbler failed with reason 2"
                        fi
                    fi
                fi
            ;;
            "SYSTEMD")
                #ARRISXB6-7776 .. check if IANAEnable is set to 0
                IANAEnable=$(syscfg show | grep "dhcpv6spool00::IANAEnable" | cut -d"=" -f2)
                if [ "$IANAEnable" = "0" ] ; then
                    echo "[$(getDateTime)] IANAEnable disabled, enable and restart dhcp6 client and dibbler"
                    syscfg set dhcpv6spool00::IANAEnable 1
                    syscfg commit
                    sleep 2
                    #need to restart dhcp client to generate dibbler conf
                    dibbler_client_enable=$(syscfg get dibbler_client_enable_v2)
                    if [ $DHCPV6C_STATUS != "false" ]; then
                        if [ "$dibbler_client_enable" = "true" ]; then
                            Dhcpv6_Client_restart "dibbler-client" "Idle"
                        else
                            Dhcpv6_Client_restart "ti_dhcp6c" "Idle"
                        fi
                    fi
                elif [ "$routerMode" = "1" ] || [ "$routerMode" = "" ] || [ "$Unit_Activated" = "0" ]; then
                    #TCCBR-4398 erouter0 not getting IPV6 prefix address from CMTS so as brlan0 also not getting IPV6 address.So unable to start dibbler service.
                    echo_t "DIBBLER : Non IPv6 mode dibbler server.conf file not present"
                else
                    if [ "$DHCPv6_ServerType" -ne 2 ] || [ "$BOX_TYPE" = "HUB4" ] || [ "$BOX_TYPE" = "SR300" ];then
                        echo_t "RDKB_PROCESS_CRASHED : Dibbler is not running, restarting the dibbler"
                        t2CountNotify "SYS_SH_Dibbler_restart"
                    fi
                    if [ -f "/etc/dibbler/server.conf" ]; then
                        BRLAN_CHKIPV6_DAD_FAILED=$(ip -6 addr show dev $PRIVATE_LAN | grep "scope link tentative dadfailed")
                        if [ "$BRLAN_CHKIPV6_DAD_FAILED" != "" ]; then
                            echo "DADFAILED : BRLAN0_DADFAILED"
                            t2CountNotify "SYS_ERROR_Dibbler_DAD_failed"

			    if [ "$BOX_TYPE" = "XB6" ] && ( [ "$MANUFACTURE" = "Technicolor" ] || [ "$MANUFACTURE" = "Sercomm" ] ); then
                                echo "DADFAILED : Recovering device from DADFAILED state"
                                # save global ipv6 address before disable it
                                v6addr=$(ip -6 addr show dev $PRIVATE_LAN | grep -i "global" | awk '{print $2}')
                                echo "1" > /proc/sys/net/ipv6/conf/$PRIVATE_LAN/disable_ipv6
                                sleep 1
                                echo "0" > /proc/sys/net/ipv6/conf/$PRIVATE_LAN/disable_ipv6
                                # re-add global ipv6 address after enabled it
                                ip -6 addr add $v6addr dev $PRIVATE_LAN
                                sleep 1

                                dibbler-server stop
                                sleep 1
                                dibbler-server start
                                sleep 5
                            elif ( [ "$MODEL_NUM" = "TG3482G" ] || [ "$MODEL_NUM" = "TG4482A" ] ) && [ $DHCPV6C_STATUS != "false" ]; then
                                echo "DADFAILED : Recovering device from DADFAILED state"
                                # save global ipv6 address before disable it
                                v6addr=$(ip -6 addr show dev $PRIVATE_LAN | grep -i "global" | awk '{print $2}')
                                if [ -f /tmp/dhcpmgr_initialized ]; then
                                    sysevent set dhcpv6_client-stop
                                else
                                    $DHCPV6_HANDLER dhcpv6_client_service_disable
                                fi
                                sysctl -w net.ipv6.conf.$PRIVATE_LAN.disable_ipv6=1
                                sysctl -w net.ipv6.conf.$PRIVATE_LAN.accept_dad=0
                                sleep 1
                                sysctl -w net.ipv6.conf.$PRIVATE_LAN.disable_ipv6=0
                                sysctl -w net.ipv6.conf.$PRIVATE_LAN.accept_dad=1
                                sleep 1
                                if [ -f /tmp/dhcpmgr_initialized ]; then
                                    sysevent set dhcpv6_client-start
                                else
                                    $DHCPV6_HANDLER dhcpv6_client_service_enable
                                fi
                                # re-add global ipv6 address after enabled it
                                ip -6 addr add $v6addr dev $PRIVATE_LAN
                                sleep 5
                            fi
                        elif [ $Sizeof_ServerConf -le 1 ]; then
                            if [ "$BOX_TYPE" = "HUB4" ]; then
                                echo "DIBBLER : Dibbler Server Config is empty"
                                echo "DIBBLER : Setting 'sysevent dibblerServer-restart restart' to trigger PAM for dibbler-server file creation"
                                sysevent set dibblerServer-restart restart
                            else
                                Dhcpv6_Client_restart "$DHCPv6_TYPE" "restart_for_dibbler-server"
                                ret_val=`echo $?`
                                if [ "$ret_val" = "1" ];then
                                    echo "DIBBLER : Dibbler Server Config is empty"
                                    t2CountNotify "SYS_ERROR_DibblerServer_emptyconf"
                                fi
                            fi
                        elif [ "$DHCPv6_ServerType" -eq 2 ] && [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ] && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ "$BOX_TYPE" != "SR213" ]; then
                            #if servertype is stateless(1-stateful,2-stateless),the ip assignment will be done through zebra process.Hence dibbler-server won't required.
                            echo_t "DHCPv6 servertype is stateless,dibbler-server restart not required"
                        else
                            dibbler-server stop
                            sleep 2
                            dibbler-server start
                        fi
                    else
                        echo_t "RDKB_PROCESS_CRASHED : dibbler server.conf file not present"
                        Dhcpv6_Client_restart "$DHCPv6_TYPE" "restart_for_dibbler-server"
                        ret_val=`echo $?`
                        if [ "$ret_val" = "2" ];then
                           echo_t "DIBBLER : Restart of dibbler failed with reason 2"
                        fi
                    fi
                fi
            ;;
        esac
    fi
    fi
    fi
fi
# xle mode ends
if [ "$xle_device_mode" -ne "1" ]; then #zebra for non xle
    #Checking the zebra is running or not
    WAN_STATUS=$(sysevent get wan-status)
    ZEBRA_PID=$(busybox pidof zebra)
     echo_t "BR_MODE:$BR_MODE ZEBRA_PID:$ZEBRA_PID WAN_STATUS:$WAN_STATUS"
    if [ "$ZEBRA_PID" = "" ] && [ "$WAN_STATUS" = "started" ]; then
        if [ "$BR_MODE" = "0" ]; then
             echo_t "$BR_MODE cat zebra.conf file: "
            filename="/var/zebra.conf"
            cat "$filename";
            echo_t "RDKB_PROCESS_CRASHED : zebra is not running, restarting the zebra"
            t2CountNotify "SYS_SH_Zebra_restart"
            /etc/utopia/registration.d/20_routing restart
            sysevent set zebra-restart
        fi
    fi
fi
case $SELFHEAL_TYPE in
    "BASE")
        #Checking the ntpd is running or not
        if [ "$WAN_TYPE" != "EPON" ]; then
            NTPD_PID=$(busybox pidof ntpd)
            if [ "$NTPD_PID" = "" ]; then
                echo_t "RDKB_PROCESS_CRASHED : NTPD is not running, restarting the NTPD"
                sysevent set ntpd-restart
            fi


            #Checking if rpcserver is running
            RPCSERVER_PID=$(busybox pidof rpcserver)
            if [ "$RPCSERVER_PID" = "" ] && [ -f /usr/bin/rpcserver ]; then
                echo_t "RDKB_PROCESS_CRASHED : RPCSERVER is not running on ARM side, restarting "
                /usr/bin/rpcserver &
            fi
        fi
    ;;
    "TCCBR")
        #Checking the ntpd is running or not for TCCBR
        if [ "$WAN_TYPE" != "EPON" ]; then
            NTPD_PID=$(busybox pidof ntpd)
            if [ "$NTPD_PID" = "" ]; then
                echo_t "RDKB_PROCESS_CRASHED : NTPD is not running, restarting the NTPD"
                sysevent set ntpd-restart
            fi
        fi
    ;;
    "SYSTEMD")
        #All CCSP Processes Now running on Single Processor. Add those Processes to Test & Diagnostic
    ;;
esac

# ARRIS XB6 => MODEL_NUM=TG3482G
# Tech CBR  => MODEL_NUM=CGA4131COM
# Tech xb6  => MODEL_NUM=CGM4140COM
# Tech XB7  => MODEL_NUM=CGM4331COM
# Tech CBR2 => MODEL_NUM=CGA4332COM
# CMX  XB7  => MODEL_NUM=TG4482A
# Tech XB8  => MODEL_NUM=CGM4981COM
# Vant XER5 => MODEL_NUM=VTER11QEL
# This critical processes checking is handled in selfheal_aggressive.sh for above platforms
# Ref: RDKB-25546
if [ "$MODEL_NUM" != "TG3482G" ] && [ "$MODEL_NUM" != "CGA4131COM" ] &&
       [ "$MODEL_NUM" != "CGM4140COM" ] && [ "$MODEL_NUM" != "CGM4331COM" ] && [ "$MODEL_NUM" != "CGM4981COM" ] && [ "$MODEL_NUM" != "CWA438TCOM" ] && [ "$MODEL_NUM" != "CGM601TCOM" ] || [ "$MODEL_NUM" != "SG417DBCT" ] && [ "$MODEL_NUM" != "TG4482A" ] && [ "$MODEL_NUM" != "CGA4332COM" ] && [ "$MODEL_NUM" != "VTER11QEL" ]
then
# Checking for WAN_INTERFACE ipv6 address
DHCPV6_ERROR_FILE="/tmp/.dhcpv6SolicitLoopError"
WAN_STATUS=$(sysevent get wan-status)
WAN_IPv4_Addr=$(ifconfig $WAN_INTERFACE | grep "inet" | grep -v "inet6")
#DHCPV6_HANDLER="/etc/utopia/service.d/service_dhcpv6_client.sh"

case $SELFHEAL_TYPE in
    "BASE"|"SYSTEMD")
        if [ "$WAN_STATUS" != "started" ]; then
            echo_t "WAN_STATUS : wan-status is $WAN_STATUS"
            if [ "$WAN_STATUS" = "stopped" ]; then
                t2CountNotify "RF_ERROR_WAN_stopped"
            fi
        fi
    ;;
    "TCCBR")
    ;;
esac

if [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ]  && [ "$BOX_TYPE" != "SR213" ]  && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ -f "$DHCPV6_ERROR_FILE" ] && [ "$WAN_STATUS" = "started" ] && [ "$WAN_IPv4_Addr" != "" ] && [ $DHCPV6C_STATUS != "false" ] && [ "$DHCPcMonitoring" != "false" ] && [ "$UseLANIFIPV6" != "true" ]; then
    isIPv6=$(ifconfig $WAN_INTERFACE | grep "inet6" | grep "Scope:Global")
    echo_t "isIPv6 = $isIPv6"
    if [ "$isIPv6" = "" ] && [ "$Unit_Activated" != "0" ]; then
        case $SELFHEAL_TYPE in
            "BASE"|"SYSTEMD")
                echo_t "[RDKB_SELFHEAL] : $DHCPV6_ERROR_FILE file present and $WAN_INTERFACE ipv6 address is empty, restarting dhcpv6 client"
            ;;
            "TCCBR")
                echo_t "[RDKB_SELFHEAL] : $DHCPV6_ERROR_FILE file present and $WAN_INTERFACE ipv6 address is empty, restarting ti_dhcp6c"
            ;;
        esac
        rm -rf $DHCPV6_ERROR_FILE
        dibbler_client_enable=$(syscfg get dibbler_client_enable_v2)
        if [ "$dibbler_client_enable" = "true" ]; then
            Dhcpv6_Client_restart "dibbler-client" "Idle"
        else
            Dhcpv6_Client_restart "ti_dhcp6c" "Idle"
        fi
    fi
fi
#Logic added in reference to RDKB-25714
#to check erouter0 has Global IPv6 or not and accordingly kill the process
#responsible for the same. The killed processes will get restarted
#by the later stages of this script.
erouter0_up_check=$(ifconfig $WAN_INTERFACE | grep "UP")
erouter0_globalv6_test=$(ifconfig $WAN_INTERFACE | grep "inet6" | grep "Scope:Global" | awk '{print $(NF-1)}' | cut -f1 -d":")
erouter_mode_check=$(syscfg get last_erouter_mode) #Check given for non IPv6 bootfiles RDKB-27963
IPV6_STATUS_CHECK_GIPV6=$(sysevent get ipv6-status) #Check given for non IPv6 bootfiles RDKB-27963
if [ "$erouter0_globalv6_test" = "" ] && [ "$WAN_STATUS" = "started" ] && [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ] && [ "$BOX_TYPE" != "SR213" ] && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ $DHCPV6C_STATUS != "false" ] && [ "$DHCPcMonitoring" != "false" ] && [ "$UseLANIFIPV6" != "true" ]; then
    case $SELFHEAL_TYPE in
        "SYSTEMD")
            if [ "$erouter0_up_check" = "" ]; then
                echo_t "[RDKB_SELFHEAL] : erouter0 is DOWN, making it UP"
                ifconfig $WAN_INTERFACE up
            fi
            if ( [ "x$IPV6_STATUS_CHECK_GIPV6" != "x" ] || [ "x$IPV6_STATUS_CHECK_GIPV6" != "xstopped" ] ) && [ "$erouter_mode_check" -ne 1 ] && [ "$Unit_Activated" != "0" ]; then
		    if ( [ "$MANUFACTURE" = "Technicolor" ] || [ "$MANUFACTURE" = "Sercomm" ] ) && [ "$BOX_TYPE" = "XB6" ] && [ $DHCPV6C_STATUS != "false" ]; then
                echo_t "[RDKB_SELFHEAL] : Killing dibbler as Global IPv6 not attached"
                dibbler_client_pid=$(ps w | grep -i dibbler-client | grep -v grep | awk '{print $1}')
                if [ -n "$dibbler_client_pid" ]; then
                    echo_t "[RDKB_AGG_SELFHEAL] : Killing dibbler-client with pid $dibbler_client_pid"
                    killall -9 dibbler-client
                fi
                if [ -f /tmp/dhcpmgr_initialized ]; then
                    sysevent set dhcpv6_client-stop
                else
                    /usr/sbin/dibbler-client stop
                fi
            elif [ "$BOX_TYPE" = "XB6" ]; then
                echo_t "DHCP_CLIENT : Killing DHCP Client for v6 as Global IPv6 not attached"
                dibbler_client_pid=$(ps w | grep -i dibbler-client | grep -v grep | awk '{print $1}')
                if [ -n "$dibbler_client_pid" ]; then
                    echo_t "[RDKB_AGG_SELFHEAL] :  Killing dibbler-client with pid $dibbler_client_pid"
                    killall -9 dibbler-client
                fi
                if [ "$MODEL_NUM" = "CGM4981COM" ] || [ "$MODEL_NUM" = "CGM601TCOM" ] || [ "$MODEL_NUM" == "CWA438TCOM" ] || [ "$MODEL_NUM" = "SG417DBCT" ]
                then
                    sh $DHCPV6_HANDLER disable
                else
                    if [ -f /tmp/dhcpmgr_initialized ]; then
                        sysevent set dhcpv6_client-stop
                    else
                        $DHCPV6_HANDLER dhcpv6_client_service_disable
                    fi
                fi
            fi
            fi
        ;;
        "BASE")
            if ( [ "x$IPV6_STATUS_CHECK_GIPV6" != "x" ] || [ "x$IPV6_STATUS_CHECK_GIPV6" != "xstopped" ] ) && [ "$erouter_mode_check" -ne 1 ] && [ "$Unit_Activated" != "0" ]; then
            task_to_be_killed=$(ps | grep -i "dhcp6c" | grep -i "erouter0" | cut -f1 -d" ")
            if [ "$task_to_be_killed" = "" ]; then
                task_to_be_killed=$(ps | grep -i "dhcp6c" | grep -i "erouter0" | cut -f2 -d" ")
            fi
            if [ "$erouter0_up_check" = "" ]; then
                echo_t "[RDKB_SELFHEAL] : erouter0 is DOWN, making it UP"
                ifconfig $WAN_INTERFACE up
                #Adding to kill ipv4 process to solve RDKB-27177
                task_to_kill=`ps w | grep udhcpc | grep erouter | cut -f1 -d " "`
                if [ "x$task_to_kill" = "x" ]; then
                    task_to_kill=`ps w | grep udhcpc | grep erouter | cut -f2 -d " "`
                fi
                if [ "x$task_to_kill" != "x" ]; then
                    kill $task_to_kill
                fi
                #RDKB-27177 fix ends here
            fi
            if [ "$task_to_be_killed" != "" ]; then
                echo_t "DHCP_CLIENT : Killing DHCP Client for v6 as Global IPv6 not attached"
                kill "$task_to_be_killed"
                sleep 3
            fi
            fi
        ;;
        "TCCBR")
            if [ "$erouter0_up_check" = "" ]; then
                echo_t "[RDKB_SELFHEAL] : erouter0 is DOWN, making it UP"
                ifconfig $WAN_INTERFACE up
            fi
            if ( [ "x$IPV6_STATUS_CHECK_GIPV6" != "x" ] || [ "x$IPV6_STATUS_CHECK_GIPV6" != "xstopped" ] ) && [ "$erouter_mode_check" -ne 1 ] && [ "$Unit_Activated" != "0" ] && [ $DHCPV6C_STATUS != "false" ]; then
                echo_t "[RDKB_SELFHEAL] : Killing dibbler as Global IPv6 not attached"
                dibbler_client_pid=$(ps w | grep -i dibbler-client | grep -v grep | awk '{print $1}')
                if [ -n "$dibbler_client_pid" ]; then
                    echo_t "[RDKB_AGG_SELFHEAL] : Killing dibbler-client with pid $dibbler_client_pid"
                    killall -9 dibbler-client
                fi
                if [ -f /tmp/dhcpmgr_initialized ]; then
                    sysevent set dhcpv6_client-stop
                else
                    /usr/sbin/dibbler-client stop
                fi
            fi
        ;;
    esac
else
    echo_t "[RDKB_SELFHEAL] : Global IPv6 is present"
fi
#Logic ends here for RDKB-25714
wan_dhcp_client_v4=1
wan_dhcp_client_v6=1
#dibbler-client selfheal not required on  SCER11BEL since WAN Unification use case will cover under WANManager.
if [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ]  && [ "$BOX_TYPE" != "SR213" ] && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ "$WAN_STATUS" = "started" ]  && [ "$DHCPcMonitoring" != "false" ] && [ "$BOX_TYPE" != "SCER11BEL" ] && [ "$BOX_TYPE" != "SCXF11BFL" ] && [ "$BOX_TYPE" != "XER2" ]; then
    wan_dhcp_client_v4=1
    wan_dhcp_client_v6=1

    #Intel Proposed RDKB Generic Bug Fix from XB6 SDK
    LAST_EROUTER_MODE=`syscfg get last_erouter_mode`

    case $SELFHEAL_TYPE in
        "BASE"|"SYSTEMD")
            UDHCPC_Enable=$(syscfg get UDHCPEnable_v2)
            dibbler_client_enable=$(syscfg get dibbler_client_enable_v2)

	    if ( ( [ "$MANUFACTURE" = "Technicolor" ] || [ "$MANUFACTURE" = "Sercomm" ] ) && [ "$BOX_TYPE" != "XB3" ] ) || [ "$WAN_TYPE" = "EPON" ] || [ "$BOX_TYPE" = "VNTXER5" ] || [ "$BOX_TYPE" = "SCER11BEL" ] || [ "$BOX_TYPE" = "SCXF11BFL" ]; then
                check_wan_dhcp_client_v4=$(ps w | grep "udhcpc" | grep "erouter")
                check_wan_dhcp_client_v6=$(ps w | grep "dibbler-client" | grep -v "grep")
            else
                if [ "$MODEL_NUM" = "TG3482G" ] || [ "$MODEL_NUM" = "TG4482A" ] || [ "$SELFHEAL_TYPE" = "BASE" -a "$BOX_TYPE" = "XB3" ]; then
                    dhcp_cli_output=$(ps w | grep "ti_" | grep "erouter0")
                    if [ "$MAPT_CONFIG" != "set" ]; then
                    if [ "$UDHCPC_Enable" = "true" ]; then
                        check_wan_dhcp_client_v4=$(ps w | grep "sbin/udhcpc" | grep "erouter")
                    else
                        check_wan_dhcp_client_v4=$(echo "$dhcp_cli_output" | grep "ti_udhcpc")
                    fi
                    fi
                    if [ "$dibbler_client_enable" = "true" ]; then
                        check_wan_dhcp_client_v6=$(ps w | grep "dibbler-client" | grep -v "grep")
                    else
                        check_wan_dhcp_client_v6=$(echo "$dhcp_cli_output" | grep "ti_dhcp6c")
                    fi
                else
                    dhcp_cli_output=$(ps w | grep "ti_" | grep "erouter0")
                    check_wan_dhcp_client_v4=$(echo "$dhcp_cli_output" | grep "ti_udhcpc")
                    check_wan_dhcp_client_v6=$(echo "$dhcp_cli_output" | grep "ti_dhcp6c")
                fi
            fi
        ;;
        "TCCBR")
            check_wan_dhcp_client_v4=$(ps w | grep "udhcpc" | grep "erouter")
            check_wan_dhcp_client_v6=$(ps w | grep "dibbler-client" | grep -v "grep")
        ;;
    esac

    case $SELFHEAL_TYPE in
        "BASE")
            if [ "$BOX_TYPE" = "XB3" ]; then

                if [ "$check_wan_dhcp_client_v4" != "" ] && [ "$check_wan_dhcp_client_v6" != "" ]; then
                    if [ "$(cat /proc/net/dbrctl/mode)"  = "standbay" ]; then
                        echo_t "RDKB_SELFHEAL : dbrctl mode is standbay, changing mode to registered"
                        echo "registered" > /proc/net/dbrctl/mode
                    fi
                fi
            fi

        ;;
        "TCCBR")
        ;;
        "SYSTEMD")
        ;;
    esac

    #Intel Proposed RDKB Generic Bug Fix from XB6 SDK
    if [ "x$check_wan_dhcp_client_v4" = "x" ] && [ "x$LAST_EROUTER_MODE" != "x2" ] && [ "$MAPT_CONFIG" != "set" ] && [ $DHCPV4C_STATUS != "false" ]; then
          echo_t "RDKB_PROCESS_CRASHED : DHCP Client for v4 is not running, need restart "
          t2CountNotify "SYS_ERROR_DHCPV4Client_notrunning"
	  wan_dhcp_client_v4=0
    fi

    if [ "$thisWAN_TYPE" != "EPON" ]; then
                    
        #Intel Proposed RDKB Generic Bug Fix from XB6 SDK
	if [ "x$check_wan_dhcp_client_v6" = "x" ] && [ "x$LAST_EROUTER_MODE" != "x1" ] && [ "$Unit_Activated" != "0" ] && [ $DHCPV6C_STATUS != "false" ]; then
        echo_t "RDKB_PROCESS_CRASHED : DHCP Client for v6 is not running, need restart"
        t2CountNotify "SYS_ERROR_DHCPV6Client_notrunning"
		wan_dhcp_client_v6=0
	fi

        DHCP_STATUS_query=$(dmcli eRT getv Device.DHCPv4.Client.1.DHCPStatus)
        DHCP_STATUS_execution=$(echo "$DHCP_STATUS_query" | grep "Execution succeed")
        DHCP_STATUS=$(echo "$DHCP_STATUS_query" | grep "value" | cut -f3 -d":" | awk '{print $1}')

        if [ "$DHCP_STATUS_execution" != "" ] && [ "$DHCP_STATUS" != "Bound" ] && [ "$DHCPcMonitoring" != "false" ] ; then

            echo_t "DHCP_CLIENT : DHCPStatusValue is $DHCP_STATUS"
            if ([ $wan_dhcp_client_v4 -eq 0 ] && [ "$MAPT_CONFIG" != "set" ] && [ $DHCPV4C_STATUS != "false" ]) || ([ $wan_dhcp_client_v6 -eq 0 ] && [ $DHCPV6C_STATUS != "false" ] ); then
                case $SELFHEAL_TYPE in
                    "BASE"|"TCCBR")
                        echo_t "DHCP_CLIENT : DHCPStatus is not Bound, restarting WAN"
                    ;;
                    "SYSTEMD")
                        echo_t "DHCP_CLIENT : DHCPStatus is $DHCP_STATUS, restarting WAN"
                    ;;
                esac
                sh /etc/utopia/service.d/service_wan.sh wan-stop
                sh /etc/utopia/service.d/service_wan.sh wan-start
                wan_dhcp_client_v4=1
                wan_dhcp_client_v6=1
            fi
        fi
    fi

    case $SELFHEAL_TYPE in
        "BASE")
            if [ $wan_dhcp_client_v4 -eq 0 ] && [ "$MAPT_CONFIG" != "set" ]; then
		    if ( [ "$MANUFACTURE" = "Technicolor" ] || [ "$MANUFACTURE" = "Sercomm" ] ) && [ "$BOX_TYPE" != "XB3" ]; then
                    V4_EXEC_CMD="/sbin/udhcpc -i erouter0 -p /tmp/udhcpc.erouter0.pid -s /etc/udhcpc.script"
                elif [ "$WAN_TYPE" = "EPON" ]; then
                    echo "Calling epon_utility.sh to restart udhcpc "
                    sh /usr/ccsp/epon_utility.sh
                else
                    if [ "$BOX_TYPE" = "XB6" -a "$MANUFACTURE" = "Arris" ] || [ "$BOX_TYPE" = "XB3" ]; then

                        if [ "$UDHCPC_Enable" = "true" ]; then
                            V4_EXEC_CMD="/sbin/udhcpc -i erouter0 -p /tmp/udhcpc.erouter0.pid -s /etc/udhcpc.script"
                        else
                            DHCPC_PID_FILE="/var/run/eRT_ti_udhcpc.pid"
                            V4_EXEC_CMD="ti_udhcpc -plugin /lib/libert_dhcpv4_plugin.so -i $WAN_INTERFACE -H DocsisGateway -p $DHCPC_PID_FILE -B -b 1"
                        fi
                    else
                        DHCPC_PID_FILE="/var/run/eRT_ti_udhcpc.pid"
                        V4_EXEC_CMD="ti_udhcpc -plugin /lib/libert_dhcpv4_plugin.so -i $WAN_INTERFACE -H DocsisGateway -p $DHCPC_PID_FILE -B -b 1"
                    fi
                fi
                echo_t "DHCP_CLIENT : Restarting DHCP Client for v4"
                eval "$V4_EXEC_CMD"
                sleep 5
                wan_dhcp_client_v4=1
            fi

            if [ $wan_dhcp_client_v6 -eq 0 ]; then
                echo_t "DHCP_CLIENT : Restarting DHCP Client for v6"
		if ( [ "$MANUFACTURE" = "Technicolor" ] || [ "$MANUFACTURE" = "Sercomm" ] ) && [ "$BOX_TYPE" != "XB3" ]; then
                    /lib/rdk/dibbler-init.sh
                    sleep 2
                    /usr/sbin/dibbler-client start
                elif [ "$WAN_TYPE" = "EPON" ]; then
                    echo "Calling dibbler_starter.sh to restart dibbler-client "
                    sh /usr/ccsp/dibbler_starter.sh
                else
                    dibbler_client_enable=$(syscfg get dibbler_client_enable_v2)
                    if [ "$dibbler_client_enable" = "true" ]; then
                        Dhcpv6_Client_restart "dibbler-client" "Idle"
                    else
                        Dhcpv6_Client_restart "ti_dhcp6c" "Idle"
                    fi
                fi
                wan_dhcp_client_v6=1
            fi
        ;;
        "TCCBR")
            if [ $wan_dhcp_client_v4 -eq 0 ] && [ "$MAPT_CONFIG" != "set" ] && [ "$DHCPcMonitoring" != "false" ]; then
                V4_EXEC_CMD="/sbin/udhcpc -i erouter0 -p /tmp/udhcpc.erouter0.pid -s /etc/udhcpc.script"
                echo_t "DHCP_CLIENT : Restarting DHCP Client for v4"
                eval "$V4_EXEC_CMD"
                sleep 5
                wan_dhcp_client_v4=1
            fi

            if [ $wan_dhcp_client_v6 -eq 0 ] && [ "$DHCPcMonitoring" != "false" ] && [ $DHCPV6C_STATUS != "false" ]; then
                echo_t "DHCP_CLIENT : Restarting DHCP Client for v6"
                if [ "$MODEL_NUM" = "CGA4332COM" ]; then
                    /lib/rdk/dibbler-init.sh
                    sleep 2
                    /usr/sbin/dibbler-client start
                else
                    sysevent set dhcpv6_client-stop
                    sysevent set dhcpv6_client-start
                fi
                wan_dhcp_client_v6=1
            fi
        ;;
        "SYSTEMD")
        ;;
    esac

fi # [ "$WAN_STATUS" = "started" ]

case $SELFHEAL_TYPE in
    "BASE")
        # Test to make sure that if mesh is enabled the backhaul tunnels are attached to the bridges
        MESH_ENABLE=$(dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.Mesh.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
        if [ "$MESH_ENABLE" = "true" ]; then
            echo_t "[RDKB_SELFHEAL] : Mesh is enabled, test if tunnels are attached to bridges"
            t2CountNotify  "WIFI_INFO_mesh_enabled"

            # Fetch mesh tunnels from the brlan0 bridge if they exist
            if [ "x$ovs_enable" = "xtrue" ];then
            	brctl0_ifaces=$(ovs-vsctl list-ifaces brlan0 | egrep "pgd")
            else
            	brctl0_ifaces=$(brctl show brlan0 | egrep "pgd")
            fi
            br0_ifaces=$(ifconfig | egrep "^pgd" | egrep "\.100" | awk '{print $1}')

            for ifn in $br0_ifaces
              do
                brFound="false"

                for br in $brctl0_ifaces
                  do
                    if [ "$br" = "$ifn" ]; then
                        brFound="true"
                    fi
                  done
                if [ "$brFound" = "false" ]; then
                    echo_t "[RDKB_SELFHEAL] : Mesh bridge $ifn missing, adding iface to brlan0"
                    if [ "x$bridgeUtilEnable" = "xtrue" || "x$ovs_enable" = "xtrue" ];then
                    	/usr/bin/bridgeUtils add-port brlan0 $ifn
                    else
                    	brctl addif brlan0 $ifn;
                    fi
                fi
              done

            # Fetch mesh tunnels from the brlan1 bridge if they exist
            if [ "$thisIS_BCI" != "yes" ]; then
                if [ "x$ovs_enable" = "xtrue" ];then
                    brctl1_ifaces=$(ovs-vsctl list-ifaces brlan1 | egrep "pgd")
                else
                    brctl1_ifaces=$(brctl show brlan1 | egrep "pgd")
                fi
                br1_ifaces=$(ifconfig | egrep "^pgd" | egrep "\.101" | awk '{print $1}')

                for ifn in $br1_ifaces
                  do
                    brFound="false"

                    for br in $brctl1_ifaces
                      do
                        if [ "$br" = "$ifn" ]; then
                            brFound="true"
                        fi
                      done
                    if [ "$brFound" = "false" ]; then
                        echo_t "[RDKB_SELFHEAL] : Mesh bridge $ifn missing, adding iface to brlan1"
                        if [ "x$bridgeUtilEnable" = "xtrue" || "x$ovs_enable" = "xtrue" ];then
                        	/usr/bin/bridgeUtils add-port brlan1 $ifn
                        else
                        	brctl addif brlan1 $ifn;
                        fi
                    fi
                  done
            fi
        fi
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
        #dibbler-client selfheal not required on SCER11BEL since WAN Unification use case will cover under WANManager.
        if [ "x$MAPT_CONFIG" != "xset" ] && [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ] && [ "$BOX_TYPE" != "SR213" ] && [ "$BOX_TYPE" != "WNXL11BWL" ] && [ $DHCPV4C_STATUS != "false" ] && [ "$DHCPcMonitoring" != "false" ] && [ "$BOX_TYPE" != "SCER11BEL" ] && [ "$BOX_TYPE" != "SCXF11BFL" ] && [ "$BOX_TYPE" != "XER2" ]; then
            if [ $wan_dhcp_client_v4 -eq 0 ]; then
                if [ "$MANUFACTURE" = "Technicolor" ]; then
                    V4_EXEC_CMD="/sbin/udhcpc -i erouter0 -p /tmp/udhcpc.erouter0.pid -s /etc/udhcpc.script"
                elif [ "$WAN_TYPE" = "EPON" ]; then
                    echo "Calling epon_utility.sh to restart udhcpc "
                    sh /usr/ccsp/epon_utility.sh
                else
                    if [ "$MODEL_NUM" = "TG3482G" ] || [ "$MODEL_NUM" = "TG4482A" ]; then

                        if [ "$UDHCPC_Enable" = "true" ]; then
                            V4_EXEC_CMD="/sbin/udhcpc -i erouter0 -p /tmp/udhcpc.erouter0.pid -s /etc/udhcpc.script"
                        else
                            #For AXB6 b -4 option is added to avoid timeout.
                            DHCPC_PID_FILE="/var/run/eRT_ti_udhcpc.pid"
                            V4_EXEC_CMD="ti_udhcpc -plugin /lib/libert_dhcpv4_plugin.so -i $WAN_INTERFACE -H DocsisGateway -p $DHCPC_PID_FILE -B -b 4"
                        fi
                    else
 
                        DHCPC_PID_FILE="/var/run/eRT_ti_udhcpc.pid"
                        V4_EXEC_CMD="ti_udhcpc -plugin /lib/libert_dhcpv4_plugin.so -i $WAN_INTERFACE -H DocsisGateway -p $DHCPC_PID_FILE -B -b 1"
                    fi
                fi

                echo_t "DHCP_CLIENT : Restarting DHCP Client for v4"
                eval "$V4_EXEC_CMD"
                sleep 5
                wan_dhcp_client_v4=1
            fi

            #ARRISXB6-8319
            #check if interface is down or default route is missing.
            if ([ "$MODEL_NUM" = "TG3482G" ] || [ "$MODEL_NUM" = "TG4482A" ]) && [ "$LAST_EROUTER_MODE" != "2" ] && [ "$MAPT_CONFIG" != "set" ] && [ $DHCPV4C_STATUS != "false" ]; then
                ip route show default | grep "default"
                if [ $? -ne 0 ] ; then
                    ifconfig $WAN_INTERFACE up
                    sleep 2



                    if [ "$UDHCPC_Enable" = "true" ]; then
                        echo_t "restart udhcp"
                        DHCPC_PID_FILE="/tmp/udhcpc.erouter0.pid"
                    else
                        echo_t "restart ti_udhcp"
                        DHCPC_PID_FILE="/var/run/eRT_ti_udhcpc.pid"
                    fi


                    if [ -f $DHCPC_PID_FILE ]; then
                        echo_t "SERVICE_DHCP : Killing $(cat $DHCPC_PID_FILE)"
                        kill -9 "$(cat $DHCPC_PID_FILE)"
                        rm -f $DHCPC_PID_FILE
                    fi


                    if [ "$UDHCPC_Enable" = "true" ]; then
                        V4_EXEC_CMD="/sbin/udhcpc -i erouter0 -p /tmp/udhcpc.erouter0.pid -s /etc/udhcpc.script"
                    else
                        #For AXB6 b -4 option is added to avoid timeout.
                        V4_EXEC_CMD="ti_udhcpc -plugin /lib/libert_dhcpv4_plugin.so -i $WAN_INTERFACE -H DocsisGateway -p $DHCPC_PID_FILE -B -b 4"
                    fi


                    echo_t "DHCP_CLIENT : Restarting DHCP Client for v4"
                    eval "$V4_EXEC_CMD"
                    sleep 5
                    wan_dhcp_client_v4=1
                fi
            fi

            if [ $wan_dhcp_client_v6 -eq 0 ] && [ $DHCPV6C_STATUS != "false" ]; then
                echo_t "DHCP_CLIENT : Restarting DHCP Client for v6"
		if ( [ "$MANUFACTURE" = "Technicolor" ] || [ "$MANUFACTURE" = "Sercomm" ] ) && [ "$BOX_TYPE" != "XB3" ] && [ ! -f /tmp/dhcpmgr_initialized ]; then
                    /lib/rdk/dibbler-init.sh
                    sleep 2
                    /usr/sbin/dibbler-client start
                elif [ "$WAN_TYPE" = "EPON" ]; then
                    echo "Calling dibbler_starter.sh to restart dibbler-client "
                    sh /usr/ccsp/dibbler_starter.sh
                else
                    dibbler_client_enable=$(syscfg get dibbler_client_enable_v2)
                    if [ "$dibbler_client_enable" = "true" ]; then
                        Dhcpv6_Client_restart "dibbler-client" "Idle"
                    else
                        Dhcpv6_Client_restart "ti_dhcp6c" "Idle"
                    fi
                fi
                wan_dhcp_client_v6=1
            fi
        fi #Not HUB4 && SR300 && SE501 && SR213 && WNXL11BWL
    ;;
esac
fi

# ARRIS XB6 => MODEL_NUM=TG3482G
# Tech CBR  => MODEL_NUM=CGA4131COM
# Tech xb6  => MODEL_NUM=CGM4140COM
# Tech XB7  => MODEL_NUM=CGM4331COM
# Tech CBR2 => MODEL_NUM=CGA4332COM
# CMX  XB7  => MODEL_NUM=TG4482A
# Tech XB8  => MODEL_NUM=CGM4981COM
# Vant XER5 => MODEL_NUM=VTER11QEL
# This critical processes checking is handled in selfheal_aggressive.sh for above platforms
# Ref: RDKB-25546
if [ "$MODEL_NUM" != "TG3482G" ] && [ "$MODEL_NUM" != "CGA4131COM" ] &&
       [ "$MODEL_NUM" != "CGM4140COM" ] && [ "$MODEL_NUM" != "CGM4331COM" ] && [ "$MODEL_NUM" != "CGM4981COM" ] && [ "$MODEL_NUM" != "CGM601TCOM" ] && [ "$MODEL_NUM" != "CWA438TCOM" ] && [ "$MODEL_NUM" != "SG417DBCT" ] &&  [ "$MODEL_NUM" != "TG4482A" ] && [ "$MODEL_NUM" != "CGA4332COM" ] && [ "$MODEL_NUM" != "VTER11QEL" ]
then
case $SELFHEAL_TYPE in
    "BASE")
    ;;
    "TCCBR")
    ;;
    "SYSTEMD")
        if [ "$MULTI_CORE" = "yes" ]; then
            if [ -f $PING_PATH/ping_peer ]; then
                ## Check Peer ip is accessible
                loop=1
                while [ $loop -le 3 ]
                  do
                    PING_RES=$(ping_peer)
                    CHECK_PING_RES=$(echo "$PING_RES" | grep "packet loss" | cut -d"," -f3 | cut -d"%" -f1)

                    if [ "$CHECK_PING_RES" != "" ]; then
                        if [ $CHECK_PING_RES -ne 100 ]; then
                            ping_success=1
                            echo_t "RDKB_SELFHEAL : Ping to Peer IP is success"
                            break
                        else
                            ping_failed=1
                        fi
                    else
                        ping_failed=1
                    fi

                    if [ $ping_failed -eq 1 ] && [ $loop -lt 3 ]; then
                        echo_t "RDKB_SELFHEAL : Ping to Peer IP failed in iteration $loop"
                        t2CountNotify "SYS_SH_pingPeerIP_Failed"
                    else
                        echo_t "RDKB_SELFHEAL : Ping to Peer IP failed after iteration $loop also ,rebooting the device"
                        t2CountNotify "SYS_SH_pingPeerIP_Failed"
                        echo_t "RDKB_REBOOT : Peer is not up ,Rebooting device "
                        echo_t "Setting Last reboot reason Peer_down"
                        reason="Peer_down"
                        rebootCount=1
                        rebootNeeded RM "" $reason $rebootCount

                    fi
                    loop=$((loop+1))
                    sleep 5
                  done
            else
                echo_t "RDKB_SELFHEAL : ping_peer command not found"
            fi

            if [ -f $PING_PATH/arping_peer ]; then
                $PING_PATH/arping_peer
            else
                echo_t "RDKB_SELFHEAL : arping_peer command not found"
            fi
        fi
    ;;
esac
fi

if [ $rebootDeviceNeeded -eq 1 ]; then

    inMaintWindow=0
    doMaintReboot=1
    case $SELFHEAL_TYPE in
        "BASE"|"SYSTEMD")
            inMaintWindow=1
            checkMaintenanceWindow
            if [ $reb_window -eq 0 ]; then
                doMaintReboot=0
            fi
        ;;
        "TCCBR")
            inMaintWindow=1
            checkMaintenanceWindow
            if [ $reb_window -eq 0 ]; then
                doMaintReboot=0
            fi
        ;;
    esac
    if [ $inMaintWindow -eq 1 ]; then
        if [ $doMaintReboot -eq 0 ]; then
            echo_t "Maintanance window for the current day is over , unit will be rebooted in next Maintanance window "
        else
            #Check if we have already flagged reboot is needed
            if [ ! -e $FLAG_REBOOT ]; then
                if [ "$SELFHEAL_TYPE" = "BASE" ] && [ $reboot_needed_atom_ro -eq 1 ]; then
                    echo_t "RDKB_REBOOT : atom is read only, rebooting the device."
                    dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootReason string atom_read_only
                    sh /etc/calc_random_time_to_reboot_dev.sh "ATOM_RO" &
                elif [ "$SELFHEAL_TYPE" = "BASE" -o "$SELFHEAL_TYPE" = "SYSTEMD" ] && [ "$thisIS_BCI" != "yes" ] && [ $rebootNeededforbrlan1 -eq 1 ]; then
                    echo_t "rebootNeededforbrlan1"
                    echo_t "RDKB_REBOOT : brlan1 interface is not up, rebooting the device."
                    echo_t "Setting Last reboot reason"
                    dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootReason string brlan1_down
                    case $SELFHEAL_TYPE in
                        "BASE")
                            dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootCounter int 1  #TBD: not in original DEVICE code
                        ;;
                        "TCCBR")
                        ;;
                        "SYSTEMD")
                        ;;
                    esac
                    echo_t "SET succeeded"
                    sh /etc/calc_random_time_to_reboot_dev.sh "" &
                else
                    echo_t "rebootDeviceNeeded"
                    sh /etc/calc_random_time_to_reboot_dev.sh "" &
                fi
                touch $FLAG_REBOOT
            else
                echo_t "Already waiting for reboot"
            fi
        fi  # [ $doMaintReboot -eq 0 ]
    fi  # [ $inMaintWindow -eq 1 ]
fi  # [ $rebootDeviceNeeded -eq 1 ]

# Checking telemetry2_0 health and recovery
T2_0_BIN="/usr/bin/telemetry2_0"
T2_0_APP="telemetry2_0"
T2_ENABLE=$(syscfg get T2Enable)
if [ ! -f $T2_0_BIN ]; then
    T2_ENABLE="false"
fi
echo_t "Telemetry 2.0 feature is $T2_ENABLE"
if [ "$T2_ENABLE" = "true" ]; then
    T2_PID=$(busybox pidof $T2_0_APP)
    if [ "$T2_PID" = "" ]; then
        echo_t "RDKB_PROCESS_CRASHED : $T2_0_APP is not running, need restart"
        if [ -f /lib/rdk/dcm.service ]; then 
            /lib/rdk/dcm.service
        fi
    fi
fi

# Checking D process running or not
case $SELFHEAL_TYPE in
      "BASE"|"SYSTEMD"|"TCCBR")
      ps -w | { echo "D process list:"; awk '$4 == "D" { count++ ; print $5 } END { if (count > 0) print "[RDKB_SELFHEAL] : There are "count " processes in D state" ; else print "[RDKB_SELFHEAL] : There is no D process running in this device" }'; }
     ;;
esac

#BWGRDK-1044 conntrack Flush monitoring
if [ "$MODEL_NUM" = "DPC3939B" ] || [ "$MODEL_NUM" = "DPC3941B" ]; then
    CONSOLE_LOGFILE=/rdklogs/logs/ArmConsolelog.txt.0;
    timestamp=$(date '+%d/%m/%Y %T')
    check_conntrack_D=`ps -w | grep -i "conntrack" | grep " D " | grep -v grep | wc -l`
    if [ $check_conntrack_D -gt 0 ]; then
        echo "$timestamp : Conntrack Log start " >> $CONSOLE_LOGFILE
        dmesg | grep conntrack >> $CONSOLE_LOGFILE
        echo "$timestamp : Conntrack Log End " >> $CONSOLE_LOGFILE
        cli system/pp/enable
    fi
fi

if [ "$MODEL_NUM" = "CGM4981COM" ] || [ "$MODEL_NUM" = "CGM601TCOM" ] || [ "$MODEL_NUM" = "CWA438TCOM" ] || [ "$MODEL_NUM" = "SG417DBCT" ] || [ "$MODEL_NUM" = "CGM4331COM" ]; then
        MESH_ENABLE=$(dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.Mesh.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
        OPENSYNC_ENABLE=$(dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.Mesh.Opensync | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
        if [ "$MESH_ENABLE" = "true" ] && [ "$OPENSYNC_ENABLE" = "true" ]; then
                echo_t "[RDKB_SELFHEAL] : Mesh is enabled, test if vlan tag is NULL "
                if [ "$OneWiFiEnabled" = "true" ] 
                then
                    echo_t "[RDKB_SELFHEAL] : OneWiFi is enabled "
                    vlantag_wl01=$( /usr/opensync/tools/ovsh s Port -w name==wl0.1 | egrep "tag" | egrep 100)
                    vlantag_wl11=$( /usr/opensync/tools/ovsh s Port -w name==wl1.1 | egrep "tag" | egrep 100)
                    if [[ ! -z "$vlantag_wl01" ]] || [[ ! -z "$vlantag_wl11" ]]; then
                            echo_t "[RDKB_SELFHEAL] : Remove port vlan tag "
                            ovs-vsctl remove port wl0.1 tag 100
                            ovs-vsctl remove port wl1.1 tag 100
                    fi
                else
                    vlantag_wl0=$( /usr/opensync/tools/ovsh s Port -w name==wl0 | egrep "tag" | egrep 100)
                    vlantag_wl1=$( /usr/opensync/tools/ovsh s Port -w name==wl1 | egrep "tag" | egrep 100)
                    if [[ ! -z "$vlantag_wl0" ]] || [[ ! -z "$vlantag_wl1" ]]; then
                            echo_t "[RDKB_SELFHEAL] : Remove port vlan tag "
                            ovs-vsctl remove port wl0 tag 100
                            ovs-vsctl remove port wl1 tag 100
                    fi
                fi
        fi
fi

# Run IGD process if not running
upnp_enabled=`syscfg get upnp_igd_enabled`
if [ "1" = "$upnp_enabled" ]; then
  check_IGD_process=`ps | grep "IGD" | grep -v grep | wc -l`
  if [ $check_IGD_process -eq 0 ]; then
	  echo_t "[RDKB_SELFHEAL] : There is no IGD process running in this device"
	  sysevent set igd-restart
  fi
fi

if [ "$MODEL_NUM" = "TG3482G" ] || [ "$MODEL_NUM" = "CGM4140COM" ]; then
        MESH_ENABLE=$(dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.Mesh.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
        OPENSYNC_ENABLE=$(dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.Mesh.Opensync | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
        if [ "$MESH_ENABLE" = "true" ] && [ "$OPENSYNC_ENABLE" = "true" ]; then
                echo_t "[RDKB_SELFHEAL] : Mesh is enabled, test if vlan tag is NULL "
                vlantag_ath0=$( /usr/opensync/tools/ovsh s Port -w name==ath0 | egrep "tag" | egrep 100)
                vlantag_ath1=$( /usr/opensync/tools/ovsh s Port -w name==ath1 | egrep "tag" | egrep 100)
                if [[ ! -z "$vlantag_ath0" ]] || [[ ! -z "$vlantag_ath1" ]]; then
                        echo_t "[RDKB_SELFHEAL] : Remove port vlan tag "
                        ovs-vsctl remove port ath0 tag 100
                        ovs-vsctl remove port ath1 tag 100
                fi
        fi
fi

if [ "$MODEL_NUM" = "VTER11QEL" ]; then 
	MESH_ENABLE=$(dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.Mesh.Enable | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
        OPENSYNC_ENABLE=$(dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.Mesh.Opensync | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
        if [ "$MESH_ENABLE" = "true" ] && [ "$OPENSYNC_ENABLE" = "true" ]; then
                echo_t "[RDKB_SELFHEAL] : Mesh is enabled, test if vlan tag is NULL "
                vlantag_ath0=$( /usr/opensync/tools/ovsh s Port -w name==ath0 | egrep "tag" | egrep 100)
                vlantag_ath1=$( /usr/opensync/tools/ovsh s Port -w name==ath1 | egrep "tag" | egrep 100)
                if [[ ! -z "$vlantag_ath0" ]] || [[ ! -z "$vlantag_ath1" ]]; then
                        echo_t "[RDKB_SELFHEAL] : Remove port vlan tag "
                        ovs-vsctl remove port ath0 tag 100
                        ovs-vsctl remove port ath1 tag 100
                fi
        fi
fi

# HCM Checks Added
hcm_mwo_pid=$(pidof MeshWifiOptimizer)
hcm_mqtt_pid=$(ps ww | grep "local_optimizer_mosquitto.conf" | grep -v grep | awk '{print $1}')
mesh_qm_pid=$(pidof qm)

get_total_cpu_time() {
    awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8}' /proc/stat
}

get_process_cpu_time() {
    awk '{print $14 + $15}' /proc/$hcm_mwo_pid/stat
}

get_cpu_meshwifi_optimizer() {
    initial_process_time=$(get_process_cpu_time)
    initial_total_time=$(get_total_cpu_time)
    sleep 1
    final_process_time=$(get_process_cpu_time)
    final_total_time=$(get_total_cpu_time)
    diff_process_time=$((final_process_time - initial_process_time))
    diff_total_time=$((final_total_time - initial_total_time))
    CPU_USAGE=$(awk "BEGIN {print ($diff_process_time / $diff_total_time) * 100}")
}

restart_mwo() {
    killall MeshWifiOptimizer
    /usr/bin/MeshWifiOptimizer
}

check_mwo_rss_selfheal() {
#Prevent MeshWifiOptimizer crossing beyond 20MB RSS
    hcm_rss_watermark="20000"
    echo_t "HCM: Current RSS Mem: $1"

    if [ "$1" -gt "$hcm_rss_watermark" ];then
        echo_t "HCM: MWO RSS memory has exceeded the RSS watermark, Selfhealing"
        restart_mwo
    else
        echo_t "HCM: MWO RSS Memory is still in the optimal range"
    fi
}

check_mwo_cpu_selfheal() {
#Prevent MeshWifiOptimizer crossing beyond 25% CPU
    hcm_cpu_watermark="25"
    echo_t "HCM: Current CPU: $1"
    if awk 'BEGIN {exit !('"$1"' > '"$hcm_cpu_watermark"')}' ; then
        echo_t "HCM: MWO CPU has exceeded the CPU watermark, Selfhealing"
        restart_mwo
    else
        echo_t "HCM: MWO CPU Memory is still in optimal range"
    fi
}

print_hcm_process_stats() {
    get_cpu_meshwifi_optimizer
    RSS=$(grep VmRSS /proc/$(pidof MeshWifiOptimizer)/status | cut -d':' -f2 | tr -d ' ' | sed 's/^[[:space:]]*//')
    VMSize=$(grep VmSize /proc/$(pidof MeshWifiOptimizer)/status | cut -d':' -f2 | tr -d ' ' | sed 's/^[[:space:]]*//')
    echo_t "HCM_PROCESS_STATS: MeshWifiOptimizer CPU Usage: $CPU_USAGE RSS: $RSS VM: $VMSize"
    CPU_RM_KB=$(echo $CPU_USAGE | awk '{gsub(/kB/, ""); print}')
    RSS_RM_KB=$(echo $RSS | awk '{gsub(/kB/, ""); print}')
    VMSize_RM_KB=$(echo $VMSize | awk '{gsub(/kB/, ""); print}')
    check_mwo_rss_selfheal $RSS_RM_KB
    check_mwo_cpu_selfheal $CPU_RM_KB
    echo_t "HCM_PROCESS_STATS: $CPU_RM_KB,$RSS_RM_KB,$VMSize_RM_KB"
}

hcm_handle_recovery() {
    if [ ! -f "/proc/$hcm_mwo_pid/status" ] && [ -f "/proc/$hcm_mqtt_pid/status" ]
    then
        echo_t "HCM_Checks: MeshWifi Optimizer not running, restarting it"
        restart_mwo
    else
        echo_t "HCM_Checks: MWO Broker not running, restarting Mesh"
        /usr/opensync/scripts/managers.init restart
    fi
}

#Restart RFC service, if the RFC sync not happened
self_heal_rfc()
{
    if [ ! -f /tmp/.rfcSyncDone ] && [ ! -f /tmp/.rfcServiceLock ]
	then
        echo_t "[RFC_SELFHEAL] : RFC sync not done.Triggering RFC Self healing"
        if [ -f /usr/ccsp/tad/selfheal_rfc.sh ]; then
            sh /usr/ccsp/tad/selfheal_rfc.sh &
        else
            echo_t "[RFC_SELFHEAL] : RFC selfheal script not found"
        fi
    fi
}

self_heal_ethwan_mode_recover()
{

    if [ "$MODEL_NUM" == "CGM601TCOM" ] || [ "$MODEL_NUM" == "CWA438TCOM" ] || [ "$MODEL_NUM" == "SG417DBCT" ];then

        echo_t "RDKB_SELFHEAL : Checking for XB10 in EthWan mode "
        CurrWanMode=$(dmcli eRT getv Device.X_RDKCENTRAL-COM_EthernetWAN.CurrentOperationalMode | grep "value" | cut -f3 -d":" | cut -f2 -d" ")
        SelWanMode=$(dmcli eRT getv Device.X_RDKCENTRAL-COM_EthernetWAN.SelectedOperationalMode | grep "value" | cut -f3 -d":" | cut -f2 -d" ")

        XB10_EWAN_ENABLE="/nvram/.xb10_enable_ethwan_mode"

	if ([ "$CurrWanMode" = "Ethernet" ] || [ "$SelWanMode" = "Ethernet" ])  && [ ! -f $XB10_EWAN_ENABLE ];then

            echo_t "RDKB_SELFHEAL : XB10 in EthWan mode and no override file detected, to recover switching to Docsis mode .."

            rm -f /nvram/ethwan_interface
            rm -f /nvram/ETHWAN_ENABLE
            syscfg set selected_wan_mode 2
            syscfg commit
	    dmcli eRT setv Device.X_RDKCENTRAL-COM_EthernetWAN.SelectedOperationalMode string DOCSIS
        fi
    fi
}

if [ "$MODEL_NUM" = "CGM4331COM" ] || [ "$MODEL_NUM" = "CGM4140COM" ] || [ "$MODEL_NUM" = "CGM4981COM" ] || [ "$MODEL_NUM" = "TG4482A" ] || [ "$MODEL_NUM" = "TG3482G" ] || [ "$MODEL_NUM" = "CGM601TCOM" ] || [ "$MODEL_NUM" = "CWA438TCOM" ] || [ "$MODEL_NUM" = "SG417DBCT" ] || [ "$MODEL_NUM" = "SCER11BEL" ] || [ "$MODEL_NUM" = "SR203" ] || [ "$MODEL_NUM" = "SR213" ] || [ "$MODEL_NUM" = "CGA4332COM" ] || [ "$MODEL_NUM" = "AYER21BEL" ]; then
    mesh_optimization_mode=$(deviceinfo.sh -optimization)
    mesh_enable=$(syscfg get mesh_enable)
    if [[ "$mesh_optimization_mode" == "monitor" || "$mesh_optimization_mode" == "enable" ]] && ! [[ "$mesh_enable" == "true" && "$mesh_optimization_mode" == "enable" ]] && ! [[ "$mesh_enable" == "false" && "$mesh_optimization_mode" == "monitor" ]]
    then
        echo_t "HCM_Checks: MWO and local broker should run in HCM mode"
        if [ ! -f "/proc/$hcm_mwo_pid/status" ] || [ ! -f "/proc/$hcm_mqtt_pid/status" ] && [ -f "/proc/$mesh_qm_pid/status" ]
        then
            echo_t "HCM_Checks: MWO or local broker not running in HCM mode, Recovery begin"
            hcm_handle_recovery
        else
            echo_t "HCM_Checks: MWO and local broker running in HCM mode"
            print_hcm_process_stats
        fi
    fi
fi

#pre-condition check for mesh enablement
precondition_check_mesh=-1

#Check for the pre-conditions, if mesh enabled and the mesh services not started
if [ "$(syscfg get mesh_enable)" = "true" ]; then
    if [ "$(busybox pidof dm)" = "" ]; then
        echo_t "[RDKB_SELFHEAL] : Mesh is enabled, check for the pre-conditions"
        check_device_in_bridge_mode=$(syscfg get bridge_mode)
        if [ "$check_device_in_bridge_mode" = "0" ]; then
            # Check the status if 2.4GHz Wifi Radio
            RadioStatus_2=$(dmcli eRT getv Device.WiFi.Radio.1.Status | grep "value" | cut -f3 -d":" | cut -f2 -d" ")

            # Check the status if 5GHz Wifi Radio
            RadioStatus_5=$(dmcli eRT getv Device.WiFi.Radio.2.Status | grep "value" | cut -f3 -d":" | cut -f2 -d" ")

            if [ "$RadioStatus_2" = "Up" ] && [ "$RadioStatus_5" = "Up" ]; then
                precondition_check_mesh=1
                echo_t "[RDKB_SELFHEAL] : precondition_check_mesh passed"
            else
                precondition_check_mesh=0
                echo_t "[RDKB_SELFHEAL] : precondition_check_mesh failed"
            fi
        fi
    else
       rm -rf /tmp/meshenable_selfheal
    fi
fi

if [ $precondition_check_mesh -eq 1 ]; then
    if [ -f /tmp/meshenable_selfheal ]; then
        if [ "$(busybox pidof dm)" = "" ] ; then
            echo_t "[RDKB_SELFHEAL] : The pre-conditions are passed, so starting the mesh service"
            systemctl start meshwifi.service
            rm -rf /tmp/meshenable_selfheal
        fi
    else
    touch /tmp/meshenable_selfheal
    fi
fi


#Restart MeshWifi services, if the Wifi_VIf_Config and Wifi_VIF_State parameters are not matching

handle_mesh_restart() {
     if [ -f /tmp/meshwifi_restart ];then
         rm -rf /tmp/meshwifi_restart
         echo_t "Mesh: Previous and current config drift seen, Restart Mesh Service"
         echo_t "Mesh: Previous and current config drift seen, Restart Mesh Service" >> /rdklogs/logs/MeshAgentLog.txt.0
         systemctl restart meshwifi.service
     else
         echo_t "Mesh: Waiting for next iteration to restart Mesh service"
         touch /tmp/meshwifi_restart
     fi
}

drift=false
probable_no_pod=false
if [ "$(syscfg get mesh_enable)" = "true" ] && [ "$(busybox pidof dm)" != "" ];then
    isOneWiFi=`grep OneWiFiEnabled /etc/device.properties | cut -d "=" -f 2`
    if [ "$isOneWiFi" = "true" ]; then
        echo_t "Using OneWiFi interfaces for WiFi back-haul"
        if [ "$MODEL_NUM" = "TG4482A" ]; then
            MESH_VAP_24=`psmcli get dmsb.l2net.13.Members.OneWiFi.Alias`
            MESH_VAP_50=`psmcli get dmsb.l2net.14.Members.OneWiFi.Alias`
        else
            MESH_VAP_24=`psmcli get dmsb.l2net.13.Members.OneWiFi`
            MESH_VAP_50=`psmcli get dmsb.l2net.14.Members.OneWiFi`
        fi
    else
        MESH_VAP_24=`psmcli get dmsb.l2net.13.Members.WiFi`
        MESH_VAP_50=`psmcli get dmsb.l2net.14.Members.WiFi`
    fi
    if [ "`/usr/opensync/tools/ovsh s Wifi_VIF_Config -w if_name=="$MESH_VAP_24"`" = "" ] && [ "`/usr/opensync/tools/ovsh s Wifi_VIF_Config -w if_name=="$MESH_VAP_50"`" = "" ]; then
       echo_t "Mesh: $MESH_VAP_24 & $MESH_VAP_50 is not present, try with cloud ifnmaes"
       MESH_VAP_24='bhaul-ap-24'
       MESH_VAP_50='bhaul-ap-50'
    fi

    ifaces="$MESH_VAP_24 $MESH_VAP_50"

    for iface in $ifaces;do
        if [ "`/usr/opensync/tools/ovsh s Wifi_VIF_Config -w if_name=="$iface" | grep if_name | cut -d'|' -f2`" != "" ]; then
            echo_t "Mesh: Checking Duplicate interface name present for $iface"
            if [ "`/usr/opensync/tools/ovsh s Wifi_VIF_Config -w if_name=="$iface" | grep if_name | cut -d'|' -f3`" != "" ]; then
             echo_t "Mesh: Duplicate interface name present for $iface"
             handle_mesh_restart
             drift=true
             break
           fi
        fi

     #Config table
     ENABLED_CONFIG="`/usr/opensync/tools/ovsh s Wifi_VIF_Config -w if_name=="$iface" | grep enabled | awk '{print $3}'`"
     MAC_LIST_CONFIG="`/usr/opensync/tools/ovsh s Wifi_VIF_Config -w if_name=="$iface" | grep mac_list | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}'`"
     MAC_LIST_TYPE_CONFIG="`/usr/opensync/tools/ovsh s Wifi_VIF_Config -w if_name=="$iface" | grep mac_list_type | awk '{print $3}'`"
     SSID_CONFIG="`/usr/opensync/tools/ovsh s Wifi_VIF_Config -w if_name=="$iface" | grep "ssid " | awk '{print $3}'`"

     if [ "$ENABLED_CONFIG" != "true" ] && [ "$iface" == "$MESH_VAP_24" ];then
         probable_no_pod=true;
     fi

     #State table
     ENABLED_STATE="`/usr/opensync/tools/ovsh s Wifi_VIF_State -w if_name=="$iface" | grep enabled | awk '{print $3}'`"
     MAC_LIST_STATE="`/usr/opensync/tools/ovsh s Wifi_VIF_State -w if_name=="$iface" | grep mac_list | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}'`"
     MAC_LIST_TYPE_STATE="`/usr/opensync/tools/ovsh s Wifi_VIF_State -w if_name=="$iface" | grep mac_list_type | awk '{print $3}'`"
     SSID_STATE="`/usr/opensync/tools/ovsh s Wifi_VIF_State -w if_name=="$iface" | grep "ssid " | awk '{print $3}'`"

     echo_t "$iface| config_enable $ENABLED_CONFIG state_enable $ENABLED_STATE  config_maclist $MAC_LIST_CONFIG state_maclist $MAC_LIST_STATE config_mactype $MAC_LIST_TYPE_CONFIG state_mactype $MAC_LIST_TYPE_STATE config_ssid $SSID_CONFIG  state_ssid $SSID_STATE"
    
     if [ $probable_no_pod = false ];then
         if [ "$ENABLED_CONFIG" != "$ENABLED_STATE" ] ||  [ "$MAC_LIST_CONFIG" != "$MAC_LIST_STATE" ] ||  [ "$MAC_LIST_TYPE_CONFIG" != "$MAC_LIST_TYPE_STATE" ] || [ "$SSID_CONFIG" != "$SSID_STATE" ]; then
              echo_t "Mesh: Config and State are mismatching for $iface"
              handle_mesh_restart
              drift=true
              break
         else
              echo_t "Mesh: Config and State are matching for $iface"
         fi
     else
         echo_t "Mesh: Skipping drift check since bhaul-ap-24 is down, pods may not be present"
     fi
 
     done
fi

if [ $drift = false ];then
   echo_t "Mesh: Both Bhauls are good"
   rm -rf /tmp/meshwifi_restart
fi

#checking TandD hung status leading to mem leak.
case $SELFHEAL_TYPE in
      "SYSTEMD")
      if [ "$MODEL_NUM" = "TG4482A" ]; then
         TDM_PID=$(busybox pidof CcspTandDSsp)
         if [ "$TDM_PID" != "" ]; then
            FanEntries=$(dmcli eRT getv Device.Thermal.FanNumberOfEntries)
            FanEntries_timeout=$(echo "$FanEntries" | grep "$CCSP_ERR_TIMEOUT")
            FanEntries_notexist=$(echo "$FanEntries" | grep "$CCSP_ERR_NOT_EXIST")
            if [ "$FanEntries_timeout" != "" ] || [ "$FanEntries_notexist" != "" ]; then
               echo_t "[RDKB_PLATFORM_ERROR] : CcspTandDSsp process is hung , restarting it"
               systemctl restart CcspTandDSsp
               t2CountNotify "SYS_ERROR_CcspTandDSspHung_restart"
            fi
         fi
      fi
      ;;
esac

if [ "$BOX_TYPE" = "WNXL11BWL" ]; then
    self_heal_rfc
fi
self_heal_dual_cron
self_heal_meshAgent_ensure_running
self_heal_meshAgent
self_heal_meshAgent_hung
self_heal_sedaemon
if [ "$BOX_TYPE" != "HUB4" ] && [ "$BOX_TYPE" != "SR300" ] && [ "$BOX_TYPE" != "SE501" ] && [ "$BOX_TYPE" != "SR213" ] && [ "$BOX_TYPE" != "WNXL11BWL" ]; then
    check_br403_is_created
fi
self_heal_ethwan_mode_recover
if [ "$T2_ENABLE" = "true" ]; then
    self_heal_t2
fi

#checking MAPT is enabled or not
if [ "$(syscfg get MAPT_Enable)" = "true" ]; then
    echo_t "[RDKB_SELFHEAL] : MAPT is enabled!"
fi

#RDKB-55218 - workaround for ovs-vswitchd cpu spike.
# Deleting and adding pgd interfaces in br106 and brlan1 will reduce cpu usage of ovs-vswitchd

# Start monitoring the ip link status in the background
ip monitor link > /tmp/check_promsc_mode.txt 2>/dev/null &
monitor_pid=$!

# Sleep for 5 seconds
sleep 5

# Kill the ip monitor process
kill $monitor_pid 2>/dev/null
wait $monitor_pid 2>/dev/null

# Fetch pgd.*106 from br106
br106_pgd_ports=$(ovs-vsctl list-ifaces br106 | grep -i pgd*)
# Count occurrences of pgd.*106 in the ip monitor output
br106_count=$(grep -o 'pgd.*106' /tmp/check_promsc_mode.txt | wc -l)

# If the count is greater than 200, delete and add pgd interfaces
if [ "$br106_count" -gt 200 ]; then
    echo_t "ovs-vswitchd process is consuming more CPU. Deleting and adding pgd interfaces in br106"
    for port in $br106_pgd_ports; do
        ovs-vsctl del-port br106 "$port"
        ovs-vsctl add-port br106 "$port"
    done
fi

# Fetch pgd.*101 from brlan1
brlan1_pgd_ports=$(ovs-vsctl list-ifaces brlan1 | grep -i pgd*)
# Count occurrences of pgd.*101 in the ip monitor output
brlan1_count=$(grep -o 'pgd.*101' /tmp/check_promsc_mode.txt | wc -l)

# If the count is greater than 200, delete and add pgd interfaces
if [ "$brlan1_count" -gt 200 ]; then
    echo_t "ovs-vswitchd process is consuming more CPU. Deleting and adding pgd interfaces in brlan1"
    for port in $brlan1_pgd_ports; do
        ovs-vsctl del-port brlan1 "$port"
        ovs-vsctl add-port brlan1 "$port"
    done
fi

# Clean up the temporary file
rm -f /tmp/check_promsc_mode.txt
