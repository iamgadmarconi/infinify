// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_PREFLIGHT_H
#define DW_PREFLIGHT_H
#include <dlfcn.h>
#include <stdint.h>
#include <sys/sysctl.h>
#include <string.h>
static int dw_preflight(uint32_t *config,int *preview) {
    int (*getConfig)(uint32_t *)=dlsym(RTLD_DEFAULT,"csr_get_active_config");
    *config=0;*preview=0;
    char args[4096]={0};size_t size=sizeof(args)-1;
    if(sysctlbyname("kern.bootargs",args,&size,NULL,0)==0) {
        char *save=NULL;for(char *token=strtok_r(args," \t",&save);token;token=strtok_r(NULL," \t",&save))if(!strcmp(token,"-arm64e_preview_abi"))*preview=1;
    }
    if(!getConfig||getConfig(config))return -1;
    // Conservative prerequisite gates; passing is NOT proof task_for_pid or
    // injection will succeed. Library validation and current OS may add gates.
    return ((*config & 0x06)==0x06 && *preview) ? 0 : 1;
}
#endif
