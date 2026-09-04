/*
 * If not stated otherwise in this file or this component's Licenses.txt file the
 * following copyright and licenses apply:
 *
 * Copyright 2015 RDK Management
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

/**********************************************************************
   Copyright [2014] [Cisco Systems, Inc.]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
**********************************************************************/

/**************************************************************************

    module: cosa_diagnostic_apis.c

        For COSA Data Model Library Development

    -------------------------------------------------------------------

    description:

        This file implementes back-end apis for the COSA Data Model Library

        *  CosaDiagCreate
        *  CosaDiagInitialize
        *  CosaDiagRemove
    -------------------------------------------------------------------

    environment:

        platform independent

    -------------------------------------------------------------------

    author:

        COSA XML TOOL CODE GENERATOR 1.0

    -------------------------------------------------------------------

    revision:

        01/11/2011    initial revision.

**************************************************************************/

#include "plugin_main_apis.h"
#include "cosa_selfheal_apis.h"
#include "cosa_logbackup_dml.h"
#include "safec_lib_common.h"
#include <syscfg/syscfg.h>
#include "secure_wrapper.h"

static char *Ipv4_Server ="Ipv4_PingServer_%d";
static char *Ipv6_Server ="Ipv6_PingServer_%d";
int g_boot_cron_mode = -1;

//static int count=0; /*RDKB-24432 : Memory usage and fragmentation selfheal*/

// Declaring selfheal scripts
char *SELF_HEAL_SCRIPTS[] = {
    "selfheal_aggressive.sh",
    "self_heal_connectivity_test.sh",
    "resource_monitor.sh"
};

//Start/stop cron jobs
typedef struct {
    const char *name;
    const char *key;
    int def_val;
} CronJob;

#define SELFHEAL_SCRIPT_COUNT (sizeof(SELF_HEAL_SCRIPTS) / sizeof(SELF_HEAL_SCRIPTS[0]))

void copy_command_output(FILE *fp, char * buf, int len)
{
    char * p;

    if (fp)
    {
        fgets(buf, len, fp);
        buf[len-1] = '\0';
        /*we need to remove the \n char in buf*/
        if ((p = strchr(buf, '\n'))) {
                *p = 0;
        }
    }
}

/* Start all self-heal scripts */
void start_self_heal_scripts() {
    for (size_t i = 0; i < SELFHEAL_SCRIPT_COUNT; i++) {
        CcspTraceWarning(("%s: Starting %s\n", __FUNCTION__, SELF_HEAL_SCRIPTS[i]));
        // Uses the shared path and script name
        v_secure_system("/usr/ccsp/tad/%s &", SELF_HEAL_SCRIPTS[i]);
    }
}
/* Stop all self-heal scripts */
void stop_self_heal_scripts() {
	FILE *fp = NULL;
    for (size_t i = 0; i < SELFHEAL_SCRIPT_COUNT; i++) {
		char buf[64] = {0};
		fp = v_secure_popen("r", "busybox pidof %s", SELF_HEAL_SCRIPTS[i]);
		if (fp != NULL)
        {
            copy_command_output(fp, buf, sizeof(buf));
            CcspTraceInfo(("%s: pidof %s returned: %s\n", __FUNCTION__, SELF_HEAL_SCRIPTS[i], buf));
            v_secure_pclose(fp);
        }
        else
        {
            CcspTraceWarning(("%s: v_secure_popen failed for %s\n", __FUNCTION__, SELF_HEAL_SCRIPTS[i]));
        }
        if (buf[0] == '\0'|| buf[0] == '\n' || buf[0] == ' ') {
            CcspTraceWarning(("%s: %s is not running\n", __FUNCTION__, SELF_HEAL_SCRIPTS[i]));
        } else {
            CcspTraceWarning(("%s: Stopping %s \n", __FUNCTION__, SELF_HEAL_SCRIPTS[i]));
            v_secure_system("kill -9 %s", buf);
        }
    }
}

/* To fetch syscfg values */
unsigned long get_interval(const char *key, int def_val) {
    // Handle fixed intervals (null keys)
    if (!key) return (unsigned long)def_val;

    char buf[32] = {0};
    unsigned long result = (unsigned long)def_val;

    if (syscfg_get(NULL, key, buf, sizeof(buf)) == 0 && buf[0] != '\0') {
        result = (unsigned long)atol(buf);
    }
    return result;
}

/* To Update Crontab (Removes old, Adds new) */
void update_cron_entry(const char *script, unsigned long interval, BOOL should_run) {
    // We always remove the old entry to avoid duplicates
    v_secure_system("crontab -l 2>/dev/null | sed '/%s/d' | crontab -", script);
    // If should_run is true, we append the new timing
    if (should_run) {
        v_secure_system("(crontab -l 2>/dev/null; echo '*/%lu * * * * /usr/ccsp/tad/%s') | crontab -", 
                        interval, script);
    }
}

/* function to Manage add/remove of cron jobs */
void manage_self_heal_cron_state(BOOL isEnabled) {
	const CronJob self_heal_scripts[] = {
        {"self_heal_connectivity_test.sh", "ConnTest_PingInterval", 60},
        {"resource_monitor.sh", "resource_monitor_interval", 15},
        {"selfheal_aggressive.sh", "AggressiveInterval", 5}
    };

    const CronJob recovery_scripts[] = {
        {"resource_monitor_recover.sh", NULL, 5}
    };

	size_t selfheal_script_count = sizeof(self_heal_scripts) / sizeof(self_heal_scripts[0]);
	size_t recovery_script_count = sizeof(recovery_scripts) / sizeof(recovery_scripts[0]);

    if (isEnabled) {
		CcspTraceInfo(("Selfheal is enabled and cron is enabled \n"));
		// Stop Cron Job of Recovery Scripts
        for (size_t i = 0; i < recovery_script_count; i++) update_cron_entry(recovery_scripts[i].name, 0, false);

		// Start Cron Jobs of Self-Heal Scripts
		for (size_t i = 0; i < selfheal_script_count; i++) {
			update_cron_entry(self_heal_scripts[i].name, get_interval(self_heal_scripts[i].key, self_heal_scripts[i].def_val), true);
		}
    } 
    else {
        // Stop Cron Job of Self-Heal and Recovery Scripts
        for (size_t i = 0; i < selfheal_script_count; i++) update_cron_entry(self_heal_scripts[i].name, 0, false);
        for (size_t i = 0; i < recovery_script_count; i++) update_cron_entry(recovery_scripts[i].name, 0, false);
    }
}

int SyncServerlistInDb(PingServerType type, int EntryCount)
{
	int urlIndex =0;
	int i =0;
	int j =0;
	errno_t rc = -1;
	for(urlIndex=1; urlIndex <= EntryCount; urlIndex++ )
	{
		char uri[256];
		char recName[64];
		rc = memset_s(uri,sizeof(uri),0,sizeof(uri));
		ERR_CHK(rc);
		rc = memset_s(recName,sizeof(recName),0,sizeof(recName));
		ERR_CHK(rc);
		if(type == PingServerType_IPv4)
		{
			rc = sprintf_s(recName, sizeof(recName), Ipv4_Server, urlIndex);
			if(rc < EOK)
			{
				ERR_CHK(rc);
			}
		}
		else
		{
			rc = sprintf_s(recName, sizeof(recName), Ipv6_Server, urlIndex);
			if(rc < EOK)
			{
				ERR_CHK(rc);
			}
		}
		syscfg_get( NULL, recName, uri, sizeof(uri));
		if(strcmp(uri,""))
		{
			i++;
		}
		else
		{
			j = urlIndex+1;
			while(j <= EntryCount)
			{
				rc = memset_s(recName,sizeof(recName),0,sizeof(recName));
				ERR_CHK(rc);
				rc = memset_s(uri,sizeof(uri),0,sizeof(uri));
				ERR_CHK(rc);
				if(type == PingServerType_IPv4)
				{
					rc = sprintf_s(recName, sizeof(recName), Ipv4_Server, j);
					if(rc < EOK)
					{
						ERR_CHK(rc);
					}
				}
				else
				{
					rc = sprintf_s(recName, sizeof(recName), Ipv6_Server, j);
					if(rc < EOK)
					{
						ERR_CHK(rc);
					}
				}
				syscfg_get( NULL, recName, uri, sizeof(uri));
				if(strcmp(uri,""))
				{
					/* copy the URL  of index j to index urlIndex. Remove entery of index j */
					SavePingServerURI(type, uri, urlIndex);
					RemovePingServerURI(type,j);
					i++;
					break;
				}
				else
				{
					j++;
				}

			}
		}

	}
		if(type == PingServerType_IPv4)
		{
			if (syscfg_set_u_commit(NULL, "Ipv4PingServer_Count", i) != 0)
			{
				CcspTraceWarning(("syscfg_set failed\n"));
			}
		}
		else
		{
			if (syscfg_set_u_commit(NULL, "Ipv6PingServer_Count", i) != 0)
			{
				CcspTraceWarning(("syscfg_set failed\n"));
			}
		}
	return i;
}
void FillEntryInList(PCOSA_DATAMODEL_SELFHEAL pSelfHeal,PCOSA_CONTEXT_SELFHEAL_LINK_OBJECT   pSelfHealCxtLink,PingServerType type)
{
	PCOSA_DML_SELFHEAL_IPv4_SERVER_TABLE pServerIpv4 = NULL;
	PCOSA_DML_SELFHEAL_IPv6_SERVER_TABLE pServerIpv6 = NULL;
	errno_t rc = -1;
	int Qdepth = 0;
    pSelfHealCxtLink = (PCOSA_CONTEXT_SELFHEAL_LINK_OBJECT)AnscAllocateMemory(sizeof(COSA_CONTEXT_SELFHEAL_LINK_OBJECT));
    if ( !pSelfHealCxtLink )
    {
        return;
    }
	if(type == PingServerType_IPv4)
	{
		Qdepth = AnscSListQueryDepth( &pSelfHeal->IPV4PingServerList );
		/* now we have this link content */
		pSelfHealCxtLink->InstanceNumber =  pSelfHeal->ulIPv4NextInstanceNumber;
		pSelfHeal->pConnTest->pIPv4Table[Qdepth].InstanceNumber =  pSelfHeal->ulIPv4NextInstanceNumber;
		pSelfHeal->ulIPv4NextInstanceNumber++;
		if (pSelfHeal->ulIPv4NextInstanceNumber == 0)
			pSelfHeal->ulIPv4NextInstanceNumber = 1;

		pServerIpv4 = (PCOSA_DML_SELFHEAL_IPv4_SERVER_TABLE)
			AnscAllocateMemory(sizeof(COSA_DML_SELFHEAL_IPv4_SERVER_TABLE));
		pServerIpv4->InstanceNumber =  pSelfHeal->ulIPv4NextInstanceNumber;
		rc = strcpy_s(pServerIpv4->Ipv4PingServerURI,
			sizeof(pServerIpv4->Ipv4PingServerURI),
			pSelfHeal->pConnTest->pIPv4Table[Qdepth].Ipv4PingServerURI);
		ERR_CHK(rc);
		pSelfHealCxtLink->hContext = (ANSC_HANDLE)pServerIpv4;
		CosaSListPushEntryByInsNum(&pSelfHeal->IPV4PingServerList, (PCOSA_CONTEXT_LINK_OBJECT)pSelfHealCxtLink);
	}
	else
	{
		Qdepth = AnscSListQueryDepth( &pSelfHeal->IPV6PingServerList );
		/* now we have this link content */
		pSelfHealCxtLink->InstanceNumber =  pSelfHeal->ulIPv6NextInstanceNumber;
		pSelfHeal->pConnTest->pIPv6Table[Qdepth].InstanceNumber =  pSelfHeal->ulIPv6NextInstanceNumber;
		pSelfHeal->ulIPv6NextInstanceNumber++;
		if (pSelfHeal->ulIPv6NextInstanceNumber == 0)
			pSelfHeal->ulIPv6NextInstanceNumber = 1;		

		pServerIpv6 = (PCOSA_DML_SELFHEAL_IPv6_SERVER_TABLE)
			AnscAllocateMemory(sizeof(COSA_DML_SELFHEAL_IPv6_SERVER_TABLE));
		pServerIpv6->InstanceNumber =  pSelfHeal->ulIPv6NextInstanceNumber;
		rc = strcpy_s(pServerIpv6->Ipv6PingServerURI,
			sizeof(pServerIpv6->Ipv6PingServerURI),
			pSelfHeal->pConnTest->pIPv6Table[Qdepth].Ipv6PingServerURI);
		ERR_CHK(rc);
		pSelfHealCxtLink->hContext = (ANSC_HANDLE)pServerIpv6;
		CosaSListPushEntryByInsNum(&pSelfHeal->IPV6PingServerList, (PCOSA_CONTEXT_LINK_OBJECT)pSelfHealCxtLink);
	}
 
}
PCOSA_DML_RESOUCE_MONITOR
CosaDmlGetSelfHealMonitorCfg(    
        ANSC_HANDLE                 hThisObject
    )
{
    PCOSA_DML_RESOUCE_MONITOR     pRescTest            = (PCOSA_DML_RESOUCE_MONITOR)NULL;

    pRescTest = (PCOSA_DML_RESOUCE_MONITOR)AnscAllocateMemory(sizeof(COSA_DML_RESOUCE_MONITOR)); //CID: 62759 -Wrong sizeof argument
    if(!pRescTest) {
        printf("\n %s Resource monitor allocation failed\n",__FUNCTION__);
        return NULL;
    }
    char buf[8];
    errno_t rc = -1;
    rc = memset_s(buf, sizeof(buf), 0, sizeof(buf));
    ERR_CHK(rc);
    syscfg_get(NULL, "resource_monitor_interval", buf, sizeof(buf));
    pRescTest->MonIntervalTime = atoi(buf);

    rc = memset_s(buf, sizeof(buf), 0, sizeof(buf));
    ERR_CHK(rc);
    syscfg_get(NULL, "avg_cpu_threshold", buf, sizeof(buf));
    pRescTest->AvgCpuThreshold = atoi(buf);

    rc = memset_s(buf, sizeof(buf), 0, sizeof(buf));
    ERR_CHK(rc);
    syscfg_get(NULL, "avg_memory_threshold", buf, sizeof(buf));
    pRescTest->AvgMemThreshold = atoi(buf);

    return pRescTest;
}



void CpuMemFragCronSchedule(ULONG uinterval, BOOL bCollectnow)
{
     if(bCollectnow == TRUE) 
     {
       if((uinterval >= 1 ) && ( uinterval <= 120 ))
       {
           CcspTraceInfo(("%s calling collection script\n",__FUNCTION__));
           /*For Featching /proc/buddyinfo data immediatelly	*/
           v_secure_system("/usr/ccsp/tad/log_buddyinfo.sh &");
       }
       else
          CcspTraceError(("%s, Time interval is not in range\n",__FUNCTION__));
     }
	/*For Featching /proc/buddyinfo data after interval	*/
	v_secure_system("/usr/ccsp/tad/cpumemfrag_cron.sh %lu &",uinterval);


}

void CosaDmlGetSelfHealCpuMemFragData(PCOSA_DML_CPU_MEM_FRAG_DMA pCpuMemFragDma )
{
        char buf[128]={0};
        errno_t rc = -1;
        /* RDKB-24432 : Memory usage and fragmentation selfheal
  	if (count > 1){   
            system("sh /usr/ccsp/tad/log_buddyinfo.sh ");
        }
        count++;*/
	if(pCpuMemFragDma->index == COSA_DML_HOST)
	{
		rc = memset_s(buf ,sizeof(buf), 0 ,sizeof(buf));
		ERR_CHK(rc);
		syscfg_get( NULL, "CpuMemFrag_Host_Dma", buf, sizeof(buf));
                if(strlen(buf) != 0)
                {
                	rc = strcpy_s(pCpuMemFragDma->dma , sizeof(pCpuMemFragDma->dma), buf );
                	ERR_CHK(rc);
                }

		rc = memset_s(buf , sizeof(buf), 0 ,sizeof(buf));
		ERR_CHK(rc);
		syscfg_get( NULL, "CpuMemFrag_Host_Dma32", buf, sizeof(buf));
                if(strlen(buf) != 0)
                {
                	rc = strcpy_s(pCpuMemFragDma->dma32 , sizeof(pCpuMemFragDma->dma32), buf );
                	ERR_CHK(rc);
                }
			
		rc = memset_s(buf , sizeof(buf), 0 ,sizeof(buf));
		ERR_CHK(rc);
		syscfg_get( NULL, "CpuMemFrag_Host_Normal", buf, sizeof(buf));
                if(strlen(buf) != 0)
                {
                	rc = strcpy_s(pCpuMemFragDma->normal, sizeof(pCpuMemFragDma->normal), buf );
                	ERR_CHK(rc);
                }

		rc = memset_s(buf , sizeof(buf), 0 ,sizeof(buf));
		ERR_CHK(rc);
		syscfg_get( NULL, "CpuMemFrag_Host_Highmem", buf, sizeof(buf));
                if(strlen(buf) != 0)
                {
                	rc = strcpy_s(pCpuMemFragDma->highmem, sizeof(pCpuMemFragDma->highmem), buf );
                	ERR_CHK(rc);
                }

		rc = memset_s(buf , sizeof(buf), 0 ,sizeof(buf));
		ERR_CHK(rc);
		syscfg_get( NULL, "CpuMemFrag_Host_Percentage", buf, sizeof(buf));
		pCpuMemFragDma->FragPercentage = atoi(buf);
	}
	else if(pCpuMemFragDma->index == COSA_DML_PEER)
	{
		rc = memset_s(buf , sizeof(buf), 0 ,sizeof(buf));
		ERR_CHK(rc);
		syscfg_get( NULL, "CpuMemFrag_Peer_Dma", buf, sizeof(buf));
                if(strlen(buf) != 0)
                {
                	rc = strcpy_s(pCpuMemFragDma->dma , sizeof(pCpuMemFragDma->dma), buf );
                	ERR_CHK(rc);
                }

		rc = memset_s(buf , sizeof(buf), 0 ,sizeof(buf));
		ERR_CHK(rc);
		syscfg_get( NULL, "CpuMemFrag_Peer_Dma32", buf, sizeof(buf));
                if(strlen(buf) != 0)
                {
                    rc = strcpy_s(pCpuMemFragDma->dma32 , sizeof(pCpuMemFragDma->dma32), buf );
                    ERR_CHK(rc);
                }
			
		rc = memset_s(buf , sizeof(buf), 0 ,sizeof(buf));
		ERR_CHK(rc);
		syscfg_get( NULL, "CpuMemFrag_Peer_Normal", buf, sizeof(buf));
                if(strlen(buf) != 0)
                {
                    rc = strcpy_s(pCpuMemFragDma->normal , sizeof(pCpuMemFragDma->normal), buf );
                    ERR_CHK(rc);
                }

		rc = memset_s(buf , sizeof(buf), 0 ,sizeof(buf));
		ERR_CHK(rc);
		syscfg_get( NULL, "CpuMemFrag_Peer_Highmem", buf, sizeof(buf));
                if(strlen(buf) != 0)
                {
                	rc = strcpy_s(pCpuMemFragDma->highmem , sizeof(pCpuMemFragDma->highmem), buf );
                	ERR_CHK(rc);
                }

		rc = memset_s(buf , sizeof(buf), 0 ,sizeof(buf));
		ERR_CHK(rc);
		syscfg_get( NULL, "CpuMemFrag_Peer_Percentage", buf, sizeof(buf));
		pCpuMemFragDma->FragPercentage = atoi(buf);
	}

}

PCOSA_DML_CPU_MEM_FRAG
CosaDmlGetSelfHealCpuMemFragCfg(    
        ANSC_HANDLE                 hThisObject
    )
{

    PCOSA_DATAMODEL_SELFHEAL      pMyObject            = (PCOSA_DATAMODEL_SELFHEAL)hThisObject;
	PCOSA_DML_CPU_MEM_FRAG     pCpuMemFrag = (PCOSA_DML_CPU_MEM_FRAG)pMyObject->pCpuMemFrag;

	pCpuMemFrag = (PCOSA_DML_CPU_MEM_FRAG)AnscAllocateMemory(sizeof(COSA_DML_CPU_MEM_FRAG));
	if(!pCpuMemFrag) 
	{
			CcspTraceWarning(("\n %s Cpu Mem Frag allocation failed\n",__FUNCTION__));
			return NULL;
	}

	pCpuMemFrag->pCpuMemFragDma = (PCOSA_DML_CPU_MEM_FRAG_DMA)AnscAllocateMemory(sizeof(COSA_DML_CPU_MEM_FRAG_DMA) * 3);
	if(!pCpuMemFrag->pCpuMemFragDma) 
	{
			CcspTraceWarning(("\n %s Cpu Mem Frag Dma allocation failed\n",__FUNCTION__));
                        AnscFreeMemory(pCpuMemFrag); //CID :56931 Resource leak
			return NULL;
	}

	CpuMemFragCronSchedule(pMyObject->CpuMemFragInterval,FALSE);
	/*Get data of Host from syscfg 	*/
	pCpuMemFrag->pCpuMemFragDma[0].index = COSA_DML_HOST;
	CosaDmlGetSelfHealCpuMemFragData(pCpuMemFrag->pCpuMemFragDma );
	pCpuMemFrag->InstanceNumber++;
	/*Get data of Peer from syscfg 	*/
	pCpuMemFrag->pCpuMemFragDma[1].index = COSA_DML_PEER;
	CosaDmlGetSelfHealCpuMemFragData((pCpuMemFrag->pCpuMemFragDma + 1));
	pCpuMemFrag->InstanceNumber++;


    return pCpuMemFrag;
}


PCOSA_DML_CONNECTIVITY_TEST
CosaDmlGetSelfHealCfg(    
        ANSC_HANDLE                 hThisObject
    )
{
	PCOSA_DATAMODEL_SELFHEAL      pMyObject            = (PCOSA_DATAMODEL_SELFHEAL)hThisObject;
	PCOSA_DML_CONNECTIVITY_TEST    pConnTest            = (PCOSA_DML_CONNECTIVITY_TEST)NULL;
	PCOSA_CONTEXT_SELFHEAL_LINK_OBJECT   pSelfHealCxtLink = NULL;
	int i=0;
	int urlIndex;
	char recName[64];
	char buf[10], dnsURL[512];
	errno_t rc = -1;
	ULONG entryCountIPv4 = 0;
	ULONG entryCountIPv6 = 0;

	get_logbackupcfg();
	pConnTest = (PCOSA_DML_CONNECTIVITY_TEST)AnscAllocateMemory(sizeof(COSA_DML_CONNECTIVITY_TEST));
	pMyObject->pConnTest = pConnTest;
	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);

	 // First time after boot, determine the mode and lock it
	if(g_boot_cron_mode == -1)
    {
		buf[0] = '\0';
        if (syscfg_get(NULL, "SelfHealCronEnable", buf, sizeof(buf)) == 0) 
        {
            g_boot_cron_mode = (strcmp(buf, "true") == 0) ? 1 : 0;
            CcspTraceInfo(("%s: Boot-time Cron Mode locked to: %s\n", 
                    __FUNCTION__, (g_boot_cron_mode ? "Cron" : "Process")));
        }
        else 
        {
            g_boot_cron_mode = 0; // Default fallback to Process Mode
        }
    }
	buf[0] = '\0';
	syscfg_get( NULL, "selfheal_enable", buf, sizeof(buf));
	pMyObject->Enable = (!strcmp(buf, "true")) ? TRUE : FALSE;
        if ( pMyObject->Enable == TRUE )
        {
#if defined(_COSA_BCM_MIPS_)
            v_secure_system("/lib/rdk/xf3_wifi_self_heal.sh &");
#endif
			if(g_boot_cron_mode == 0)
            {
                CcspTraceInfo(("SelfHealCronEnable is disabled, running as background process\n"));
                start_self_heal_scripts();
            }
	    }  

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "max_reboot_count", buf, sizeof(buf));
	pMyObject->MaxRebootCnt = atoi(buf);

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "Free_Mem_Threshold", buf, sizeof(buf));
	pMyObject->FreeMemThreshold= atoi(buf);

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "Mem_Frag_Threshold", buf, sizeof(buf));
	pMyObject->MemFragThreshold = atoi(buf);

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "CpuMemFrag_Interval", buf, sizeof(buf));
	pMyObject->CpuMemFragInterval = atoi(buf);

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "max_reset_count", buf, sizeof(buf));
	/* RDKB-13228 */
	pMyObject->MaxResetCnt = atoi(buf);

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "Selfheal_DiagnosticMode", buf, sizeof(buf));
	pMyObject->DiagnosticMode = (!strcmp(buf, "true")) ? TRUE : FALSE;

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "diagMode_LogUploadFrequency", buf, sizeof(buf));
	pMyObject->DiagModeLogUploadFrequency = atoi(buf);

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "selfheal_dns_pingtest_enable", buf, sizeof(buf));
	pMyObject->DNSPingTest_Enable = (!strcmp(buf, "true")) ? TRUE : FALSE;

	rc = memset_s(dnsURL,sizeof(dnsURL),0,sizeof(dnsURL));
	ERR_CHK(rc);
	syscfg_get( NULL, "selfheal_dns_pingtest_url", dnsURL, sizeof(dnsURL));
	if( '\0' != dnsURL[ 0 ] )
	{
		rc = strcpy_s(pMyObject->DNSPingTest_URL, sizeof(pMyObject->DNSPingTest_URL), dnsURL);
		ERR_CHK(rc);
	}
	else
	{
		pMyObject->DNSPingTest_URL[ 0 ] = '\0';
	}

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "ConnTest_PingInterval", buf, sizeof(buf));
	pConnTest->PingInterval = atoi(buf);
	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "ConnTest_NumPingsPerServer", buf, sizeof(buf));
	pConnTest->PingCount = atoi(buf);
	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "ConnTest_MinNumPingServer", buf, sizeof(buf));
	pConnTest->MinPingServer = atoi(buf);
	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "ConnTest_PingRespWaitTime", buf, sizeof(buf));
	pConnTest->WaitTime = atoi(buf);

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "ConnTest_CorrectiveAction", buf, sizeof(buf));
	pConnTest->CorrectiveAction = (!strcmp(buf, "true")) ? TRUE : FALSE;

    rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
    ERR_CHK(rc);
    syscfg_get( NULL, "router_reboot_Interval", buf, sizeof(buf));
    pConnTest->RouterRebootInterval = atoi(buf);

	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "Ipv4PingServer_Count", buf, sizeof(buf));
	pConnTest->IPv4EntryCount = atoi(buf);
	entryCountIPv4 = AnscSListQueryDepth(&pMyObject->IPV4PingServerList);
        UNREFERENCED_PARAMETER(entryCountIPv4);
	pConnTest->IPv4EntryCount = SyncServerlistInDb(PingServerType_IPv4, pConnTest->IPv4EntryCount);
	if ( pConnTest->IPv4EntryCount != 0 )
	{
		pConnTest->pIPv4Table     = (PCOSA_DML_SELFHEAL_IPv4_SERVER_TABLE)AnscAllocateMemory(sizeof(COSA_DML_SELFHEAL_IPv4_SERVER_TABLE) * pConnTest->IPv4EntryCount);
	}

	for(urlIndex=1; urlIndex <= pConnTest->IPv4EntryCount; urlIndex++ )
	{
		char uri[256];
		rc = memset_s(uri,sizeof(uri),0,sizeof(uri));
		ERR_CHK(rc);
		rc = memset_s(recName,sizeof(recName),0,sizeof(recName));
		ERR_CHK(rc);
		rc = sprintf_s(recName, sizeof(recName), Ipv4_Server, urlIndex);
		if(rc < EOK)
		{
			ERR_CHK(rc);
		}
		syscfg_get( NULL, recName, uri, sizeof(uri));
		if(strcmp(uri,""))
		{
			rc = strcpy_s(pConnTest->pIPv4Table[i].Ipv4PingServerURI ,  sizeof(pConnTest->pIPv4Table[i].Ipv4PingServerURI), uri);
			ERR_CHK(rc);
		}
		i++;
		/* Push entery in the IPv4 queue */
		FillEntryInList(pMyObject,pSelfHealCxtLink,PingServerType_IPv4);
	}
	rc = memset_s(buf,sizeof(buf),0,sizeof(buf));
	ERR_CHK(rc);
	syscfg_get( NULL, "Ipv6PingServer_Count", buf, sizeof(buf));
	pConnTest->IPv6EntryCount = atoi(buf);
	entryCountIPv6 = AnscSListQueryDepth(&pMyObject->IPV6PingServerList);
        UNREFERENCED_PARAMETER(entryCountIPv6);
	pConnTest->IPv6EntryCount = SyncServerlistInDb(PingServerType_IPv6,pConnTest->IPv6EntryCount);
	if ( pConnTest->IPv6EntryCount != 0 )
	{
		pConnTest->pIPv6Table = (PCOSA_DML_SELFHEAL_IPv6_SERVER_TABLE)AnscAllocateMemory(sizeof(COSA_DML_SELFHEAL_IPv6_SERVER_TABLE) * pConnTest->IPv6EntryCount);
	}
	i=0;
	for(urlIndex=1; urlIndex <= pConnTest->IPv6EntryCount; urlIndex++ )
	{
		char uri[256];
		rc = memset_s(uri,sizeof(uri),0,sizeof(uri));
		ERR_CHK(rc);
		rc = memset_s(recName,sizeof(recName),0,sizeof(recName));
		ERR_CHK(rc);
		rc = sprintf_s(recName, sizeof(recName), Ipv6_Server, urlIndex);
		if(rc < EOK)
		{
			ERR_CHK(rc);
		}
		syscfg_get( NULL, recName, uri, sizeof(uri));
		if(strcmp(uri,""))
		{
			rc = strcpy_s(pConnTest->pIPv6Table[i].Ipv6PingServerURI , sizeof(pConnTest->pIPv6Table[i].Ipv6PingServerURI), uri);
			ERR_CHK(rc);
		}
		i++;
		/* Push entery in the IPv6 queue */
		FillEntryInList(pMyObject,pSelfHealCxtLink,PingServerType_IPv6);
	}
	return pConnTest;
}

/**********************************************************************

    caller:     owner of the object

    prototype:

        ANSC_HANDLE
        CosaDiagCreate
            (
                VOID
            );

    description:

        This function constructs cosa SelfHeal object and return handle.

    argument:

    return:     newly created nat object.

**********************************************************************/

ANSC_HANDLE
CosaSelfHealCreate
    (
        VOID
    )
{
    PCOSA_DATAMODEL_SELFHEAL            pMyObject    = (PCOSA_DATAMODEL_SELFHEAL)NULL;

    /*
     * We create object by first allocating memory for holding the variables and member functions.
     */
    pMyObject = (PCOSA_DATAMODEL_SELFHEAL)AnscAllocateMemory(sizeof(COSA_DATAMODEL_SELFHEAL));
    if ( !pMyObject )
    {
        return  (ANSC_HANDLE)NULL;
    }

    /*
     * Initialize the common variables and functions for a container object.
     */
    pMyObject->Oid               = COSA_DATAMODEL_DIAG_OID;
    pMyObject->Create            = CosaSelfHealCreate;
    pMyObject->Remove            = CosaSelfHealRemove;
    pMyObject->Initialize        = CosaSelfHealInitialize;

    pMyObject->Initialize   ((ANSC_HANDLE)pMyObject);
    return  (ANSC_HANDLE)pMyObject;
}

/**********************************************************************

    caller:     self

    prototype:

        ANSC_STATUS
        CosaSelfHealInitialize
            (
                ANSC_HANDLE                 hThisObject
            );

    description:

        This function initiate  cosa SelfHeal object and return handle.

    argument:   ANSC_HANDLE                 hThisObject
                This handle is actually the pointer of this object
                itself.

    return:     operation status.

**********************************************************************/

ANSC_STATUS
CosaSelfHealInitialize
    (
        ANSC_HANDLE                 hThisObject
    )
{
    ANSC_STATUS                     returnStatus         = ANSC_STATUS_SUCCESS;
    PCOSA_DATAMODEL_SELFHEAL            pMyObject            = (PCOSA_DATAMODEL_SELFHEAL )hThisObject;
    char buf[8] = {0};
    errno_t rc = -1;
	
    /* Initiation all functions */
    AnscSListInitializeHeader( &pMyObject->IPV4PingServerList );
    AnscSListInitializeHeader( &pMyObject->IPV6PingServerList );
    pMyObject->MaxInstanceNumber        = 0;
    pMyObject->ulIPv4NextInstanceNumber   = 1;
	pMyObject->ulIPv6NextInstanceNumber   = 1;
    pMyObject->PreviousVisitTime        = 0;

    /* Initialize log backup from syscfg db*/
    pMyObject->NoWaitLogSync		= FALSE;
    pMyObject->LogBackupThreshold	= 0;

    if (syscfg_get(NULL, "log_backup_enable", buf, sizeof(buf)) == 0)
    {
        if (strlen(buf) != 0)
        {
            pMyObject->NoWaitLogSync = (strcmp(buf,"true") ? FALSE : TRUE);
        }
    }

    rc = memset_s(buf, sizeof(buf), 0, sizeof(buf));
    ERR_CHK(rc);
    if (syscfg_get( NULL, "log_backup_threshold", buf, sizeof(buf)) == 0)
    {
        if (strlen(buf) != 0)
        {
            pMyObject->LogBackupThreshold =  atoi(buf);
        }
    }

	
    pMyObject->pConnTest = CosaDmlGetSelfHealCfg((ANSC_HANDLE)pMyObject);
    pMyObject->pResMonitor = CosaDmlGetSelfHealMonitorCfg((ANSC_HANDLE)pMyObject);
    pMyObject->pCpuMemFrag = CosaDmlGetSelfHealCpuMemFragCfg((ANSC_HANDLE)pMyObject);

    return returnStatus;
}

/**********************************************************************

    caller:     self

    prototype:

        ANSC_STATUS
        CosaDiagRemove
            (
                ANSC_HANDLE                 hThisObject
            );

    description:

        This function initiate  cosa SelfHeal object and return handle.

    argument:   ANSC_HANDLE                 hThisObject
                This handle is actually the pointer of this object
                itself.

    return:     operation status.

**********************************************************************/

ANSC_STATUS
CosaSelfHealRemove
    (
        ANSC_HANDLE                 hThisObject
    )
{
    ANSC_STATUS                     returnStatus = ANSC_STATUS_SUCCESS;
    PCOSA_DATAMODEL_SELFHEAL            pMyObject    = (PCOSA_DATAMODEL_SELFHEAL)hThisObject;

    /*RDKB-7457, CID-33295, null check before free */
    if ( pMyObject->pConnTest)
    {
        /* Remove necessary resounce */
        if ( pMyObject->pConnTest->pIPv4Table)
        {
            AnscFreeMemory(pMyObject->pConnTest->pIPv4Table );
        }
        if ( pMyObject->pConnTest->pIPv6Table)
        {
            AnscFreeMemory(pMyObject->pConnTest->pIPv6Table );
        }
        AnscFreeMemory(pMyObject->pConnTest);
        pMyObject->pConnTest = NULL;
    }
    if ( pMyObject->pResMonitor )
    {
        AnscFreeMemory( pMyObject->pResMonitor );
        pMyObject->pResMonitor = NULL;
    }

    /* Remove self */
    AnscFreeMemory((ANSC_HANDLE)pMyObject);
    return returnStatus;
}
void SavePingServerURI(PingServerType type, char *URL, int InstNum)
{
		char recName[256];
                errno_t rc = -1;
		memset(recName,0,sizeof(recName));
		if(type == PingServerType_IPv4)
		{
			rc = sprintf_s(recName, sizeof(recName), Ipv4_Server, InstNum);
			if(rc < EOK)
			{
				ERR_CHK(rc);
			}
		}
		else
		{
			rc = sprintf_s(recName, sizeof(recName), Ipv6_Server, InstNum);
			if(rc < EOK)
			{
				ERR_CHK(rc);
			}
		}
		if (syscfg_set_commit(NULL, recName, URL) != 0)
		{
			CcspTraceWarning(("syscfg_set failed\n"));
		}
}

ANSC_STATUS RemovePingServerURI(PingServerType type, int InstNum)
{
		ANSC_STATUS                     returnStatus = ANSC_STATUS_SUCCESS;
		char recName[256] = {0};
		errno_t rc = -1;

		if(type == PingServerType_IPv4)
		{
			rc = sprintf_s(recName, sizeof(recName), Ipv4_Server, InstNum);
			if(rc < EOK)
			{
				ERR_CHK(rc);
			}
		}
		else
		{
			rc = sprintf_s(recName, sizeof(recName), Ipv6_Server, InstNum);
			if(rc < EOK)
			{
				ERR_CHK(rc);
			}
		}
		if (syscfg_unset(NULL, recName) != 0) 
		{
			CcspTraceWarning(("syscfg_unset failed\n"));
			return ANSC_STATUS_FAILURE;
		}
		else 
		{
			if (syscfg_commit() != 0) 
			{
				CcspTraceWarning(("syscfg_commit failed\n"));
				return ANSC_STATUS_FAILURE;
			}
		}
		return returnStatus;
}

ANSC_STATUS CosaDmlModifySelfHealDiagnosticModeStatus( ANSC_HANDLE hThisObject, 
																    BOOL        bValue )
{
	ANSC_STATUS		ReturnStatus    = ANSC_STATUS_SUCCESS;
	BOOLEAN 		bProcessFurther = TRUE;

	/* Validate received param  */		
	if( NULL == hThisObject )
	{
		bProcessFurther = FALSE;
		ReturnStatus    = ANSC_STATUS_FAILURE;
		CcspTraceError(("[%s] hThisObject is NULL\n", __FUNCTION__ ));
	}

	if( bProcessFurther )
	{
		PCOSA_DATAMODEL_SELFHEAL	  pMyObject  = (PCOSA_DATAMODEL_SELFHEAL)hThisObject;
		PCOSA_DML_CONNECTIVITY_TEST   pConnTest  = (PCOSA_DML_CONNECTIVITY_TEST)NULL;

		pConnTest = pMyObject->pConnTest;

		if( NULL == pConnTest )
		{
			bProcessFurther = FALSE;
			ReturnStatus	= ANSC_STATUS_FAILURE;
			CcspTraceError(("[%s] pConnTest is NULL\n", __FUNCTION__ ));
		}

		if( bProcessFurther )
		{
			/* 
			  * Set connectivity corrective action flag based on DiagnosticMode 
			  * flag as below,
			  * 
			  *  1. If "DiagnosticMode == TRUE" then need to set "ConnTest_CorrectiveAction 
			  *      as FALSE". To restrict corrective action from connectivity test
			  *
			  *  2. If "DiagnosticMode == FALSE" then need to set "ConnTest_CorrectiveAction 
			  *      as TRUE". To allow corrective action from connectivity test
			  */
			if ( 0 == syscfg_set_commit( NULL,
								  "ConnTest_CorrectiveAction", 
								  ( ( bValue == TRUE ) ?  "false" : "true" ) ) ) 
			{
					pConnTest->CorrectiveAction = ( ( bValue == TRUE ) ?  FALSE : TRUE );
			}
			
			/* 
			  * Set diagnostic mode flag to restrict the corrective action from both resource monitor and self heal 
			  * connectivity side 
			  */
			if ( 0 == syscfg_set_commit( NULL,
								   "Selfheal_DiagnosticMode", 
								   ( ( bValue == TRUE ) ?  "true" : "false" ) ) ) 
			{
					pMyObject->DiagnosticMode = ( ( bValue == TRUE ) ?  TRUE : FALSE );
			}

                        /* Modify the cron scheduling based on configured Loguploadfrequency */
			CosaSelfHealAPIModifyCronSchedule( TRUE );
                  
			CcspTraceInfo(("[%s] DiagnosticMode:[ %d ] CorrectiveAction:[ %d ]\n",
													__FUNCTION__,
													pMyObject->DiagnosticMode,
													pConnTest->CorrectiveAction ));
		}
	}

	return ReturnStatus;
}

ANSC_STATUS CosaDmlModifySelfHealDNSPingTestStatus( ANSC_HANDLE hThisObject, 
															    BOOL        bValue )
{
	ANSC_STATUS		ReturnStatus    = ANSC_STATUS_SUCCESS;
	BOOLEAN 		bProcessFurther = TRUE;

	/* Validate received param  */		
	if( NULL == hThisObject )
	{
		bProcessFurther = FALSE;
		ReturnStatus    = ANSC_STATUS_FAILURE;
		CcspTraceError(("[%s] hThisObject is NULL\n", __FUNCTION__ ));
	}

	if( bProcessFurther )
	{
		PCOSA_DATAMODEL_SELFHEAL	  pMyObject  = (PCOSA_DATAMODEL_SELFHEAL)hThisObject;

		/* Modify the DNS ping test flag */
		if ( 0 == syscfg_set_commit( NULL,
							  "selfheal_dns_pingtest_enable", 
							  ( ( bValue == TRUE ) ? "true" : "false" ) ) ) 
		{
				pMyObject->DNSPingTest_Enable = bValue;
		}

		CcspTraceInfo(("[%s] DNSPingTest_Enable:[ %d ]\n",
									__FUNCTION__,
									pMyObject->DNSPingTest_Enable ));
	}

	return ReturnStatus;
}

ANSC_STATUS CosaDmlModifySelfHealDNSPingTestURL( ANSC_HANDLE hThisObject, 
															  PCHAR  	  pString )
{
	ANSC_STATUS		ReturnStatus    = ANSC_STATUS_SUCCESS;
	BOOLEAN 		bProcessFurther = TRUE;
	errno_t rc = -1;

	/* Validate received param  */		
	if(( NULL == hThisObject ) || \
	   ( NULL == pString ) 
	   )  
	{
		bProcessFurther = FALSE;
		ReturnStatus    = ANSC_STATUS_FAILURE;
		CcspTraceError(("[%s] hThisObject/pString is NULL\n", __FUNCTION__ ));
	}

	if( bProcessFurther )
	{
		PCOSA_DATAMODEL_SELFHEAL	  pMyObject  = (PCOSA_DATAMODEL_SELFHEAL)hThisObject;

		/* Modify the DNS ping test flag */
		if ( 0 == syscfg_set_commit( NULL,
							  "selfheal_dns_pingtest_url", 
							  pString ) ) 
		{
			rc = memset_s(pMyObject->DNSPingTest_URL, sizeof( pMyObject->DNSPingTest_URL ), 0, sizeof( pMyObject->DNSPingTest_URL ));
			ERR_CHK(rc);
			rc = strcpy_s(pMyObject->DNSPingTest_URL, sizeof(pMyObject->DNSPingTest_URL), pString);
			ERR_CHK(rc);
		}

		CcspTraceInfo(("[%s] DNSPingTest_URL:[ %s ]\n",
									__FUNCTION__,
									pMyObject->DNSPingTest_URL ));
	}

	return ReturnStatus;
}

VOID CosaSelfHealAPIModifyCronSchedule( BOOL bForceRun )
{
	char buf[10] = {0};

	syscfg_get( NULL, "Selfheal_DiagnosticMode", buf, sizeof(buf));

	if( ( 0 == strcmp(buf, "true") ) || \
		( TRUE == bForceRun )
	  )
	{
		/* 
		* We need to modify the cron scheduling based on configured Loguploadfrequency 
		*/
		CcspTraceInfo(("%s - Modify DCM cron schedule\n",__FUNCTION__ ));
		
		v_secure_system("/lib/rdk/DCMCronreschedule.sh &");
	}
}

/**********************************************************************
    prototype
        char* RemoveSpaces
            (
                char*    str
            );
    description:
        This function is called to remove spaces in config file
    argument:
            char*    str,    Input string;
    return:
            char*
**********************************************************************/
char* RemoveSpaces(char *str)
{
    int i=0,j=0;
    while(str[i] != '\0')
    {
        if (str[i] != ' ')
            str[j++] = str[i];
        i++;
    }
    str[j] = '\0';
    return str;
}

/**********************************************************************
    prototype
        void CosaReadProcAnalConfig
            (
                const char*    paramname,
                char*          res
            );
    description:
        This function is called to remove spaces in config file
    argument:
            const char*    paramname,      ParamName
            char*          res,            ParamValue;
    return:
            void
**********************************************************************/
void CosaReadProcAnalConfig(const char *paramname, char *res)
{
    char tmp_string[BUF_128] = {0};
    char* tmp = NULL;
    char* pch = NULL;
    char *tmp_file = NULL;
    FILE *fp = NULL;
    errno_t rc = -1;

    GET_CPA_CONF_FILE(tmp_file);
    fp = fopen(tmp_file,"r");

    if(fp)
    {
        while(fgets(tmp_string,BUF_128,fp)!= NULL)
        {
             if(strstr(tmp_string,paramname))
             {
                tmp=RemoveSpaces(tmp_string);
                pch=strchr(tmp,'=');
                pch=pch+1;
                rc = strcpy_s(res,BUF_64,pch);
                ERR_CHK(rc);
                break;
            }
            rc = memset_s(tmp_string,sizeof(tmp_string),0,sizeof(tmp_string));
            ERR_CHK(rc);
        }
        fclose(fp);
    }
}

/**********************************************************************
    prototype
        void CosaWriteProcAnalConfig
            (
                const char*    paramname,
                char*          res
            );
    description:
        This function is called to remove spaces in config file
    argument:
            const char*    paramname,      ParamName
            char*          res,            ParamValue;
    return:
            void
**********************************************************************/
void CosaWriteProcAnalConfig(const char *paramname, char *res)
{
    int ret = 0;
    FILE *fp = NULL;
    SYNC_CPA_CONF_FILE();
    ret = v_secure_system("sed -i '/%s/d' "CPA_CONFIG_FILE, paramname);
    if(ret != 0)
    {
         CcspTraceError(("%s - System Command failure\n",__FUNCTION__ ));
         return;
    }

    fp = fopen(CPA_CONFIG_FILE, "a");
    if(fp)
    {
        fprintf(fp, CPA_PARAM_NAME_PREPEND"%s = %s\n", paramname, res);
        fclose(fp);
    }
}

/**********************************************************************
    prototype
        int CosaIsProcAnalRunning()
    description:
        This function is called to check if ProcAnal is running or not
    argument:
        NULL
    return:
        1 - If proc anal running
        0 - If proc anal not running
**********************************************************************/
int CosaIsProcAnalRunning()
{
    char buf[BUF_128] = {0};
    FILE *fp;

    fp = v_secure_popen("r", "busybox pidof cpuprocanalyzer");
    if ( fp == 0 )
    {
        CcspTraceInfo(("%s: Not able to read cpuprocanalyser pid\n", __FUNCTION__));
    }
    else
    {
        copy_command_output(fp, buf, sizeof(buf));
        v_secure_pclose(fp);
    }

    if(*buf)
    {
        CcspTraceInfo(("%s: CPUProcAnalyzer is RUNNING!\n", __FUNCTION__));
        return 1;
    }
    else
    {
        CcspTraceInfo(("%s: CPUProcAnalyzer is NOT RUNNING!\n", __FUNCTION__));
        return 0;
    }
}
