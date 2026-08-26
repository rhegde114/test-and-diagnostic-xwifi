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
            CcspTraceInfo(("%s: Initializing publicVap_util. \n", __FUNCTION__));
            v_secure_system("/usr/bin/xwifi_diagdata -v 10,21 -i 30000");
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
