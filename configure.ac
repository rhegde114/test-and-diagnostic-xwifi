##########################################################################
# If not stated otherwise in this file or this component's Licenses.txt
# file the following copyright and licenses apply:
#
# Copyright 2015 RDK Management
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################
#                                              -*- Autoconf -*-
# Process this file with autoconf to produce configure script.
#

AC_PREREQ([2.65])
AC_INIT([diagnostic], [1.0], [BUG-REPORT-ADDRESS])
AM_INIT_AUTOMAKE
LT_INIT

AC_ARG_ENABLE([unitTestDockerSupport],
             AS_HELP_STRING([--enable-unitTestDockerSupport],[enable Docker support for unit testing (default is no)]),
             [
              case "${enableval}" in
                yes)
                  UNIT_TEST_DOCKER_SUPPORT=true
                  m4_if(m4_sysval,[0],[AC_CONFIG_FILES([source/test/Makefile source/test/CcspTandD_Dml_Test/Makefile])])
                  ;;
                no)
                  UNIT_TEST_DOCKER_SUPPORT=false
                  AC_MSG_WARN([Docker support is disabled])
                  ;;
                *)
                  AC_MSG_ERROR([bad value ${enableval} for --enable-unitTestDockerSupport])
                  ;;
              esac
             ],
             [AC_MSG_WARN([Docker support is disabled])])

AM_CONDITIONAL([UNIT_TEST_DOCKER_SUPPORT], [test x$UNIT_TEST_DOCKER_SUPPORT = xtrue])

AC_PREFIX_DEFAULT(`pwd`)
AC_ENABLE_SHARED
AC_DISABLE_STATIC

AC_CONFIG_HEADERS([config.h])
AC_CONFIG_MACRO_DIR([m4])

# Checks for programs.
AC_PROG_CC
AC_PROG_CXX
AC_PROG_INSTALL
AM_PROG_CC_C_O
AM_PROG_LIBTOOL(libtool)

# Checks for header files.
AC_CHECK_HEADERS([stdlib.h string.h unistd.h])

# Checks for typedefs, structures, and compiler characteristics.
AC_HEADER_STDBOOL
AC_C_INLINE

# Checks for library functions.
AC_FUNC_MALLOC

AC_ARG_ENABLE([mta],
[  --enable-mta    Turn on mta],
[case "${enableval}" in
  yes) ENABLE_MTA=true ;;
  no)  ENABLE_MTA=false ;;
  *) AC_MSG_ERROR([bad value ${enableval} for --enable-mta]) ;;
esac],[ENABLE_MTA=false])
AM_CONDITIONAL([ENABLE_MTA], [test x$ENABLE_MTA = xtrue])

# Checks for Core net lib Feature Support
AC_ARG_ENABLE([core_net_lib_feature_support],
[  --enable-core_net_lib_feature_support=val Turn on core_net_lib Feature, val=true or false],
[case "${enableval}" in
  yes) core_net_lib_feature_support=true ;;
  no)  core_net_lib_feature_support=false ;;
  *) AC_MSG_ERROR([bad value ${enableval} for --enable-core_net_lib_feature_support]) ;;
esac],[core_net_lib_feature_support=false])
AM_CONDITIONAL(CORE_NET_LIB_FEATURE_SUPPORT, test x"$core_net_lib_feature_support" = x"true")

RDK_SCHEDULER_CFLAGS=" "
RDK_SCHEDULER=no
AC_ARG_ENABLE([rdk_scheduler],
        AS_HELP_STRING([--enable-rdk_scheduler],[enable rdk_scheduler]),
        [
          case "${enableval}" in
           yes) RDK_SCHEDULER_CFLAGS="-DRDK_SCHEDULER_ENABLED"
                RDK_SCHEDULER=yes ;;
           no) AC_MSG_ERROR([rdk_scheduler is disabled]) ;;
          *) AC_MSG_ERROR([bad value ${enableval} for --enable-rdk_scheduler]) ;;
           esac
           ],
         [echo "rdk scheduler is disabled."])

AM_CONDITIONAL([FEATURE_RDK_SCHEDULER], [test $RDK_SCHEDULER = yes])
AC_SUBST(RDK_SCHEDULER_CFLAGS)

DEVICE_PRIORITIZATION_CFLAGS=" "
DEVICE_PRIORITIZATION=no
AC_ARG_ENABLE([device_prioritization],
        AS_HELP_STRING([--enable-device_prioritization],[enable device_prioritization]),
        [
          case "${enableval}" in
           yes) DEVICE_PRIORITIZATION_CFLAGS="-DDEVICE_PRIORITIZATION_ENABLED"
                DEVICE_PRIORITIZATION=yes ;;
           no) AC_MSG_ERROR([device_prioritization is disabled]) ;;
          *) AC_MSG_ERROR([bad value ${enableval} for --enable-device_prioritization]) ;;
           esac
           ],
         [echo "device prioritization is disabled."])

AM_CONDITIONAL([FEATURE_DEVICE_PRIORITIZATION], [test $DEVICE_PRIORITIZATION = yes])
AC_SUBST(DEVICE_PRIORITIZATION_CFLAGS)

AC_ARG_ENABLE([resourceoptimization],
             AS_HELP_STRING([--enable-resourceoptimization],[enable resource optimization (default is no)]),
             [
              case "${enableval}" in
               yes) RESOURCE_OPTIMIZATION_ENABLED=true;;
               no)  RESOURCE_OPTIMIZATION_ENABLED=false;;
               *) AC_MSG_ERROR([bad value ${enableval} for --enable-resourceoptimization]);;
              esac
             ],
             [echo "resourceoptimization is disabled"])
AM_CONDITIONAL(FEATURE_RESOURCE_OPTIMIZATION, test "x$RESOURCE_OPTIMIZATION_ENABLED" = xtrue)

AC_ARG_ENABLE([warehousediagnostics],
             AS_HELP_STRING([--enable-warehousediagnostics],[enable warehouse diagnostics (default is no)]),
             [
              case "${enableval}" in
               yes) WAREHOUSE_DIAGNOSTICS_ENABLED=true;;
               no)  WAREHOUSE_DIAGNOSTICS_ENABLED=false;;
               *) AC_MSG_ERROR([bad value ${enableval} for --enable-warehousediagnostics]);;
              esac
             ],
             [echo "warehousediagnostics is disabled"])
AM_CONDITIONAL(FEATURE_WAREHOUSE_DIAGNOSTICS, test "x$WAREHOUSE_DIAGNOSTICS_ENABLED" = xtrue)

AC_CONFIG_FILES(
  source/LatencyMeasurement/ServiceMonitor/Makefile
  source/xwifi_diagdata/xWifiMonitor/Makefile
	source/TandDSsp/Makefile
	source/dmltad/Makefile
	source/util/Makefile
	source/Makefile
	source/xle_selfheal/Makefile
  source/xwifi_diagdata/xwifi_client_info/Makefile
  source-arm/diagnostic/BbhmDiagIpPing/Makefile
  source-arm/dmltad/Makefile
  source/ImageHealthChecker/Makefile
  source/LatencyMeasurement/Makefile
  source/LatencyMeasurement/TR-181/Makefile
  source/LatencyMeasurement/xNetSniffer/Makefile 
  source/LatencyMeasurement/xNetDP/Makefile
  source/DevicePrioritization/Makefile
  source/DevicePrioritization/TR-181/Makefile
	Makefile
)

AC_SUBST(UNIT_TEST_DOCKER_SUPPORT)

AC_OUTPUT

