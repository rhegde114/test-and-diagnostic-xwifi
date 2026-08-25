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

bin_PROGRAMS = CcspTandDSsp

CcspTandDSsp_CPPFLAGS = -I$(top_srcdir)/source/diagnostic/include \
                        -I${top_srcdir}/source/LatencyMeasurement/ServiceMonitor/include \
                        -I${top_srcdir}/source/xwifi_diagdata/xWifiMonitor/include \
                        -I$(top_srcdir)/source/diagnostic/BbhmDiagIpPing \
                        -I$(top_srcdir)/source/dmltad \
                        -I$(top_srcdir)/source/TandDSsp \
                        -I$(top_srcdir)/source/LatencyMeasurement/TR-181 \
                        -I$(top_srcdir)/source/TandDSsp \
                        -I${PKG_CONFIG_SYSROOT_DIR}$(includedir)/rbus

if FEATURE_DEVICE_PRIORITIZATION
CcspTandDSsp_CPPFLAGS += -I$(top_srcdir)/source/DevicePrioritization/TR-181
CcspTandDSsp_CFLAGS = $(DEVICE_PRIORITIZATION_CFLAGS)
endif

CcspTandDSsp_SOURCES = tad_rbus_apis.c ssp_messagebus_interface.c ssp_action_priv.c ssp_main.c ssp_action.c ssp_messagebus_interface_priv.c dm_pack_datamodel.c current_time.c webcfg_selfheal.c
CcspTandDSsp_LDFLAGS = -lccsp_common -ldl -rdynamic -lrbus -lsyscfg -lsecure_wrapper -ltelemetry_msgsender -lcjson -lmsgpackc

CcspTandDSsp_DEPENDENCIES = ${top_builddir}/source/LatencyMeasurement/TR-181/libLowLatency.la \
                            ${top_builddir}/source/LatencyMeasurement/ServiceMonitor/libCcspTandDSsp_ServiceMonitor.la 
                            ${top_builddir}/source/xwifi_diagdata/xWifiMonitor/libCcspTandDSsp_xwifidiagdata.la

if FEATURE_DEVICE_PRIORITIZATION
CcspTandDSsp_DEPENDENCIES += ${top_builddir}/source/DevicePrioritization/TR-181/libDevicePrio.la
endif

CcspTandDSsp_LDADD = $(CcspTandDSsp_DEPENDENCIES)
