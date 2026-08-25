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

#ifdef __GNUC__
#if (!defined _NO_EXECINFO_H_)
#include <execinfo.h>
#endif
#endif

#include "ssp_global.h"
#ifdef INCLUDE_BREAKPAD
#include "breakpad_wrapper.h"
#endif
#include "stdlib.h"
#include "safec_lib_common.h"
#include "ServiceMonitor.h"
#include "xwifiServiceMonitor.h"
#include "tad_rbus_apis.h"
#include "lowlatency_apis.h"
#include "current_time.h"
#include <telemetry_busmessage_sender.h>
#include "webcfg_selfheal.h"

#ifdef DEVICE_PRIORITIZATION_ENABLED
#include "device_prio_apis.h"
#endif //#ifdef DEVICE_PRIORITIZATION_ENABLED

PDSLH_CPE_CONTROLLER_OBJECT     pDslhCpeController      = NULL;
PCOMPONENT_COMMON_DM            g_pComponent_Common_Dm  = NULL;
PCCSP_FC_CONTEXT                pTadFcContext           = (PCCSP_FC_CONTEXT            )NULL;
PCCSP_CCD_INTERFACE             pTadCcdIf               = (PCCSP_CCD_INTERFACE         )NULL;
PCCC_MBI_INTERFACE              pTadMbiIf               = (PCCC_MBI_INTERFACE          )NULL;
char                            g_Subsystem[32]         = {0};
BOOL                            g_bActive               = FALSE;
//extern int Xnet_Services_Config_Init();
int  cmd_dispatch(int  command)
{
    char*                           pParamNames[]      = {"Device.IP.Diagnostics.IPPing."};
    parameterValStruct_t**          ppReturnVal        = NULL;
    int                             ulReturnValCount   = 0;
    int                             i                  = 0;

    switch ( command )
    {
            case	'e' :

                CcspTraceInfo(("Connect to bus daemon...\n"));

            {
                char                            CName[256];
                errno_t                         rc = -1;

                rc = sprintf_s(CName, sizeof(CName), "%s%s", g_Subsystem, CCSP_COMPONENT_ID_TAD);
                if(rc < EOK)
                {
                    ERR_CHK(rc);
                }

                ssp_TadMbi_MessageBusEngage
                    ( 
                        CName,
                        CCSP_MSG_BUS_CFG,
                        CCSP_COMPONENT_PATH_TAD
                    );
            }


                ssp_create_tad();
                ssp_engage_tad();

                g_bActive = TRUE;

                CcspTraceInfo(("Test & Diagnostic Module loaded successfully...\n"));

            break;

            case    'r' :

            CcspCcMbi_GetParameterValues
                (
                    DSLH_MPA_ACCESS_CONTROL_ACS,
                    pParamNames,
                    1,
                    &ulReturnValCount,
                    &ppReturnVal,
                    NULL
                );



            for ( i = 0; i < ulReturnValCount; i++ )
            {
                CcspTraceWarning(("Parameter %d name: %s value: %s \n", i+1, ppReturnVal[i]->parameterName, ppReturnVal[i]->parameterValue));
            }


/*
            CcspCcMbi_GetParameterNames
                (
                    "Device.DeviceInfo.",
                    0,
                    &ulReturnValCount,
                    &ppReturnValNames
                );

            for ( i = 0; i < ulReturnValCount; i++ )
            {
                CcspTraceWarning(("Parameter %d name: %s bWritable: %d \n", i+1, ppReturnValNames[i]->parameterName, ppReturnValNames[i]->writable));
            }
*/
/*
            CcspCcMbi_GetParameterAttributes
                (
                    pParamNames,
                    1,
                    &ulReturnValCount,
                    &ppReturnvalAttr
                );
*/
/*
            CcspCcMbi_DeleteTblRow
                (
                    123,
                    "Device.X_CISCO_COM_SWDownload.SWDownload.1."
                );
*/

			break;

        case    'm':

                AnscPrintComponentMemoryTable(pComponentName);

                break;

        case    't':

                AnscTraceMemoryTable();

                break;

        case    'c':

                ssp_cancel_tad();

                break;

        default:
            break;
    }

    return 0;
}

static void _print_stack_backtrace(void)
{
#ifdef __GNUC__
#if (!defined _COSA_SIM_) && (!defined _NO_EXECINFO_H_)
        void* tracePtrs[100];
        char** funcNames = NULL;
        int i, count = 0;

        int fd;
        const char* path = "/nvram/tadssp_backtrace";
        fd = open(path, O_RDWR | O_CREAT);
        if (fd < 0)
        {
            fprintf(stderr, "failed to open backtrace file: %s", path);
            return;
        }

        count = backtrace( tracePtrs, 100 );
        backtrace_symbols_fd( tracePtrs, count, fd );
        close(fd);

        funcNames = backtrace_symbols( tracePtrs, count );

        if ( funcNames ) {
            // Print the stack trace
            for( i = 0; i < count; i++ )
                printf("%s\n", funcNames[i] );

            // Free the string pointers
            free( funcNames );
        }
#endif
#endif
}

static void daemonize(void) {
	switch (fork()) {
	case 0:
		break;
	case -1:
		// Error
		CcspTraceInfo(("Error daemonizing (fork)! %d - %s\n", errno, strerror(
				errno)));
		exit(0);
		break;
	default:
		_exit(0);
	}

	if (setsid() < 	0) {
		CcspTraceInfo(("Error demonizing (setsid)! %d - %s\n", errno, strerror(errno)));
		exit(0);
	}

//	chdir("/");


#ifndef  _DEBUG

	int fd;
	fd = open("/dev/null", O_RDONLY);
	if (fd != 0) {
		dup2(fd, 0);
		close(fd);
	}
	fd = open("/dev/null", O_WRONLY);
	if (fd != 1) {
		dup2(fd, 1);
		close(fd);
	}
	fd = open("/dev/null", O_WRONLY);
	if (fd != 2) {
		dup2(fd, 2);
		close(fd);
	}
#endif
}

void sig_handler(int sig)
{
    if ( sig == SIGINT ) {
    	signal(SIGINT, sig_handler); /* reset it to this function */
    	CcspTraceError(("SIGINT received!\n"));
        exit(0);
    }
    else if ( sig == SIGUSR1 ) {
    	signal(SIGUSR1, sig_handler); /* reset it to this function */
    	CcspTraceWarning(("SIGUSR1 received!\n"));
    }
    else if ( sig == SIGUSR2 ) {
    	CcspTraceWarning(("SIGUSR2 received!\n"));
    }
    else if ( sig == SIGCHLD ) {
    	signal(SIGCHLD, sig_handler); /* reset it to this function */
    	CcspTraceWarning(("SIGCHLD received!\n"));
    }
    else if ( sig == SIGPIPE ) {
    	signal(SIGPIPE, sig_handler); /* reset it to this function */
    	CcspTraceWarning(("SIGPIPE received!\n"));
    }
    else {
    	/* get stack trace first */
    	_print_stack_backtrace();
    	CcspTraceError(("Signal %d received, exiting!\n", sig));
    	exit(0);
    }

}


int main(int argc, char* argv[])
{
    int                             cmdChar            = 0;
    BOOL                            bRunAsDaemon       = TRUE;
    int                             idx                = 0;
    errno_t                         rc                 = -1;

    // Buffer characters till newline for stdout and stderr
    setlinebuf(stdout);
    setlinebuf(stderr);

#if defined(_DEBUG) && defined(_COSA_SIM_)
    AnscSetTraceLevel(CCSP_TRACE_LEVEL_INFO);
#endif

	t2_init("CcspTandDSsp");
    for (idx = 1; idx < argc; idx++)
    {
        if ( (strcmp(argv[idx], "-subsys") == 0) )
        {
            if ((idx+1) < argc)
            {
                rc = strcpy_s(g_Subsystem, sizeof(g_Subsystem), argv[idx+1]);
                ERR_CHK(rc);
                CcspTraceWarning(("\nSubsystem is %s\n", g_Subsystem));
            }
            else
            {
                CcspTraceError(("Argument missing after -subsys\n"));
            }
        }
        else if ( strcmp(argv[idx], "-c") == 0 )
        {
            bRunAsDaemon = FALSE;
        }
    }

    /* Set the global pComponentName */
    pComponentName = CCSP_COMPONENT_NAME_TAD;

#ifdef   _DEBUG
    /*AnscSetTraceLevel(CCSP_TRACE_LEVEL_INFO);*/
#endif

    if ( bRunAsDaemon )
        daemonize();
#ifdef INCLUDE_BREAKPAD
    breakpad_ExceptionHandler();
#else

    signal(SIGTERM, sig_handler);
    signal(SIGINT, sig_handler);
    /*signal(SIGCHLD, sig_handler);*/
    signal(SIGUSR1, sig_handler);
    signal(SIGUSR2, sig_handler);

    signal(SIGSEGV, sig_handler);
    signal(SIGBUS, sig_handler);
    signal(SIGKILL, sig_handler);
    signal(SIGFPE, sig_handler);
    signal(SIGILL, sig_handler);
    signal(SIGQUIT, sig_handler);
    signal(SIGHUP, sig_handler);
    signal(SIGPIPE, SIG_IGN);
#endif
//    if (write_pid_file("/var/tmp/CcspTandDSsp.pid") != 0)
//        fprintf(stderr, "%s: fail to write PID file\n", argv[0]);

    cmd_dispatch('e');

    /* Init TAD Rbus */
    tadRbusInit();

    // Init LatencyMeasurement
    LatencyMeasurementInit();

    //Xwifi Diag Data Service Initialization
    monitorService_xwifi_Init();

    /* SelfHeal Subdoc Version Mismatch
       webcfg_selfheal_start() spawns a detached thread that waits until the
       Device.X_RDK_WebConfig.webcfgSubdocForceReset element is available on RBUS.
       Readiness is detected by temporarily subscribing to the element's event,
       indicating the webcfg component has registered its data elements.
       This avoids the boot-time race where T&D attempts rbus_setStr before
       webcfg has finished its rbus_regDataElements() call. */
    initWebcfgProperties(WEBCFG_PROPERTIES_FILE);
    webcfg_selfheal_start();

    //create a thread to update time thread for ethwan enable mode
    BOOL ethwanEnabled = FALSE;
    ethwanEnabled = IsEthWanEnabled();
    #if defined(RDKB_EXTENDER_ENABLED) || defined(PON_GATEWAY)
  	int callUpdate = 1;
    #else
  	int callUpdate = 0;
    #endif
  
    if(ethwanEnabled || callUpdate == 1)
    {
        updateTimeThread_create();
    }

#ifdef DEVICE_PRIORITIZATION_ENABLED
    // Init device prioritization
    DevicePrioInit();
#endif

    if ( bRunAsDaemon )
    {
        while(1)
        {
            sleep(30);
        }
    }
    else
    {
        while ( cmdChar != 'q' )
        {
            cmdChar = getchar();

            sleep(30);
            cmd_dispatch(cmdChar);
        }
    }

    if ( g_bActive )
    {
        ssp_cancel_tad();

        g_bActive = FALSE;
    }

    return 0;
}


