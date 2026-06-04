/**
 * @file	dbger.h
 * @brief	Log module. This file provides code for UART or RTT to output the LOG.
 *          The priority levels are as follows:
				1. [AST]: Assert      (Highest)
                2.[ERR]:Error
                3.[WAR]:Warnning
                4.[INF]:Info
                5.[DBG]:Debug
                6. [VBS]: Verbose     (Lowest)
 *
 * @note HOW TO USE RTT LOG:
 *        1. MUST enable the STDOUT in MDK-ARM -> RTE -> Compiler -> I/O -> STDOUT(user);
 *		  2. If LOG_BY_RTT, you can get the LOG in J-Link RTT Viewer;
 *		  3. If LOG_BY_UART, you can get the LOG in any UART assistant, like PuTTY;
 *		  4. you can output the LOG by LOG_xxx() micro for different LOG level, or just by printf();
 *
 * @note HOW TO USE RTT JSCOPE:
 *        1. global define
              #pragma pack(push, 1)   // byte alignment start
              typedef struct {
                uint16_t u2;
                uint8_t i1;
              } JSCOPE_TYPE_t;
              #pragma pack(pop)       // byte alignment end
              #define JSCOPE_BUF_LEN  512
              uint8_t JSCOPE_BUF[JSCOPE_BUF_LEN] __attribute__((aligned(4)));
 *        2. init
              LOG_INIT();
              // "u4"=uint32_t, "u1"=uint8_t, "i2"=int16_t, "t4"=timestamp in us.    // option: t4 u1/2/4 i/1/2/4
              SEGGER_RTT_ConfigUpBuffer(1, "JScope_u2i1", JSCOPE_BUF, JSCOPE_BUF_LEN, SEGGER_RTT_MODE_NO_BLOCK_SKIP);    // JSCOPE_BUF must define by global buf
 *        3. send data
              JSCOPE_TYPE_t jscopeData;
              while(1) {
                  jscopeData.u2 = HAL_GetTick() & 0xFFFF;
                  jscopeData.i1++;
                  SEGGER_RTT_Write(1, &jscopeData, sizeof(jscopeData));
              }
 *        4. Seems CAN'T add "t4"? I always failed.
 *            
 *
 * @author	shadowthreed@gmail.com
 * @date	20240714
 *			20240809	update: same API for UART and RTT
 *          20250616    updata: add JSCOPE
 *          20251126    updata: support RTT CMD
 */

#ifndef __DBGER_H__
#define __DBGER_H__

#ifdef __cplusplus
extern "C"
{
#endif

#define LOG_ENABLE 			1
#define LOG_BY_RTT 			1
#define LOG_BY_UART			(!LOG_BY_RTT)
#define LOG_LEVEL 			5 		// the priority less than or queal to LOG_LEVEL will be output
#define LOG_COLOR_ENABLE 	0
#define LOG_TEST_EN			0
#define LOG_PLATFORM		0		// 0:MDK_ARM	1:Linux
#define RTT_CMD_ENABLE      1

#if LOG_ENABLE
	#include <string.h>
	// strrchr(str, ch): return the last position of ch in str, or NULL
	#define __FILENAME__ (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__) 
#endif

#if LOG_ENABLE && LOG_COLOR_ENABLE
	// set LOG color
	#define COLOR_RED 		"\033[31m"
	#define COLOR_PINK 		"\033[35m"
	#define COLOR_YELLOW 	"\033[33m"
	#define COLOR_GREEN 	"\033[32m"
	#define COLOR_GRAY 		"\033[37m"
	// default white
	#define COLOR_DEFAULT 	"\033[0m" 	
#else
	#define COLOR_RED
	#define COLOR_PINK
	#define COLOR_YELLOW
	#define COLOR_GREEN
	#define COLOR_GRAY
	#define COLOR_DEFAULT
#endif

#if LOG_ENABLE
	#include <stdio.h>
	#if LOG_PLATFORM == 0	// MDK_ARM
	#include "RTE_Components.h"
	#ifndef RTE_Compiler_IO_STDOUT_User
		#error	must enable STDOUT in MDK-ARM -> RTE -> Compiler -> I/O -> STDOUT(user).
	#endif
	#endif
#endif

#if LOG_ENABLE
#if LOG_BY_RTT
	// SEGGER_RTT_SetTerminal(2); 	SEGGER_RTT_SetTerminal(3);  keep for user, eg: terminal2 default for printing protocol data
	#include "SEGGER_RTT.h"
	#include <stdint.h>
	#define LOG_INIT()		SEGGER_RTT_Init()
	#define LOG_DAT(...)	do { if(LOG_LEVEL >= 1) { SEGGER_RTT_SetTerminal(2); printf(__VA_ARGS__); SEGGER_RTT_SetTerminal(1); }} while(0)		// for print protocol data
	#define LOG_AST(...)    do { if(LOG_LEVEL >= 1) { SEGGER_RTT_SetTerminal(0); printf(COLOR_RED 		"[AST:%s:%d] ", __FILENAME__, __LINE__); printf(__VA_ARGS__); printf("%s", COLOR_DEFAULT ""); SEGGER_RTT_SetTerminal(1); }} while(0)
	#define LOG_ERR(...)    do { if(LOG_LEVEL >= 2) { SEGGER_RTT_SetTerminal(0); printf(COLOR_PINK 		"[ERR:%s:%d] ", __FILENAME__, __LINE__); printf(__VA_ARGS__); printf("%s", COLOR_DEFAULT ""); SEGGER_RTT_SetTerminal(1); }} while(0)
	#define LOG_WAR(...)    do { if(LOG_LEVEL >= 3) { SEGGER_RTT_SetTerminal(0); printf(COLOR_YELLOW 	"[WAR:%s:%d] ", __FILENAME__, __LINE__); printf(__VA_ARGS__); printf("%s", COLOR_DEFAULT ""); SEGGER_RTT_SetTerminal(1); }} while(0)
	#define LOG_INF(...)    do { if(LOG_LEVEL >= 4) { printf(__VA_ARGS__); }} while(0)
	#define LOG_DBG(...)    do { if(LOG_LEVEL >= 5) { printf(__VA_ARGS__); }} while(0)
	#define LOG_VBS(...)    do { if(LOG_LEVEL >= 6) { printf(__VA_ARGS__); }} while(0)
	#define LOG_INT(...)	do { if(LOG_LEVEL >= 1) { printf(__VA_ARGS__); }} while(0)
    
    #if RTT_CMD_ENABLE
        #define RTT_CMD_BUF_LEN     32
        extern char RTT_cmd_buf[RTT_CMD_BUF_LEN];
        size_t get_RTT_cmd(void);      // return 1 for cmd valid; return 0 for cmd invalid;
    #endif  // RTT_CMD_ENABLE
#elif LOG_BY_UART
	#include <stdio.h>
	#define LOG_INIT()		MX_USART1_UART_Init()
	#define LOG_AST(...)    do { if(LOG_LEVEL >= 1) { printf(COLOR_RED 		"[AST:%s:%d] ", __FILENAME__, __LINE__); printf(__VA_ARGS__); printf("%s", COLOR_DEFAULT ""); }} while(0)
	#define LOG_ERR(...)    do { if(LOG_LEVEL >= 2) { printf(COLOR_PINK 	"[ERR:%s:%d] ", __FILENAME__, __LINE__); printf(__VA_ARGS__); printf("%s", COLOR_DEFAULT ""); }} while(0)
	#define LOG_WAR(...)    do { if(LOG_LEVEL >= 3) { printf(COLOR_YELLOW 	"[WAR:%s:%d] ", __FILENAME__, __LINE__); printf(__VA_ARGS__); printf("%s", COLOR_DEFAULT ""); }} while(0)
	#define LOG_INF(...)    do { if(LOG_LEVEL >= 4) { printf(__VA_ARGS__); }} while(0)
	#define LOG_DBG(...)    do { if(LOG_LEVEL >= 5) { printf(__VA_ARGS__); }} while(0)
	#define LOG_VBS(...)    do { if(LOG_LEVEL >= 6) { printf(__VA_ARGS__); }} while(0)
	#define LOG_INT(...)
#endif
#else
	#define LOG_INIT()
	#define LOG_AST(...)
	#define LOG_ERR(...)
	#define LOG_WAR(...)
	#define LOG_INF(...)
	#define LOG_DBG(...)
	#define LOG_VBS(...)
	#define LOG_INT(...)
#endif

#ifdef __cplusplus
}
#endif

#if LOG_TEST_EN
	#define LOG_TEST() log_test()
	void log_test(void);
#else
	#define LOG_TEST()
#endif

#endif // __DBGER_H__
