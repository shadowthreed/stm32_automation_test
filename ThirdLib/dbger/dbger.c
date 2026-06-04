/**
 * @file 	dbger.c
 * @author	shadowthreed@gmail.com
 * @date	20240714
 *			20240809 update: 
 *						1. add stdout_putchar() for RTT;
 *						2. add log_test();
 */
#include "dbger.h"

#if LOG_ENABLE

#if LOG_BY_UART

#include "usart.h"
#if LOG_PLATFORM == 0		// MDK_ARM
int stdout_putchar (int ch)
{
	uint8_t cha = ch;
	HAL_UART_Transmit(&huart1, &cha, 1, 10);
	return ch;
}
#elif LOG_PLATFORM == 1		// Linux
int __io_putchar(int ch, FILE *f) {
	(void)f;
	uint8_t cha = ch;
	HAL_UART_Transmit(&huart1, &cha, 1, 10);
	return ch;
}
#endif

#elif LOG_BY_RTT

#if LOG_PLATFORM == 0		// MDK_ARM
int stdout_putchar (int ch)
{
	SEGGER_RTT_PutChar(0, ch);
	return ch;
}
#elif LOG_PLATFORM == 1		// Linux
int __io_putchar(int ch, FILE *f) {
	(void)f;
	SEGGER_RTT_PutChar(0, ch);
	return ch;
}
#endif  // LOG_PLATFORM

#if RTT_CMD_ENABLE
char RTT_cmd_buf[RTT_CMD_BUF_LEN];
size_t get_RTT_cmd(void)
{
    static size_t index = 0;
    size_t cmd_len = 0;
    int ch = SEGGER_RTT_GetKey();
    if(ch != -1) {
        if(ch == '\n' || ch == '\r') {
            if(index > 0) {
                RTT_cmd_buf[index] = '\0';
                //LOG_DBG("%s\n", RTT_cmd_buf);
                cmd_len = index;
                index = 0;
            }
        } else {
            if(index < (sizeof(RTT_cmd_buf) - 1)) {
                RTT_cmd_buf[index++] = ch;
            }
        }
    }
    return cmd_len;
}
#endif  // RTT_CMD_ENABLE

#endif

#if LOG_TEST_EN
void log_test(void)
{
	float valf = 3.14;
	char str[] = "LOG TEST";
	
	LOG_INIT();
	for(uint8_t i = 0; i < 2; i++) {
		LOG_AST("AST LOG: int[%02d], float[%6.3f], str[%10s]\n", i, valf, str);
		LOG_ERR("ERR LOG: int[%2d], float[%+6.3f], str[%10s]\n", i, valf, str);
		LOG_WAR("WAR LOG: int[%-2d], float[%-6.3f], str[%-10s]\n", i, valf, str);
		LOG_INF("INF LOG: int[%d], float[%f], str[%s]\n", i, valf, str);
		LOG_DBG("DBG LOG: int[%d], float[%f], str[%s]\n", i, valf, str);
		LOG_VBS("VBS LOG: int[%d], float[%f], str[%s]\n", i, valf, str);
		printf("\n");

        size_t cmd_len = get_RTT_cmd();
        if(cmd_len) {
            LOG_DBG("cmd[%s] len[%d]\n", RTT_cmd_buf, cmd_len);
            if(strncmp(RTT_cmd_buf, "test1", 5) == 0) {
                LOG_DBG("process test1 cmd\n");
            } else if(strncmp(RTT_cmd_buf, "test2", 5) == 0) {
                LOG_DBG("process test2 cmd\n");
            } else {
                LOG_DBG("cmd[%s] NOT exist\n", RTT_cmd_buf);
            }
        }
	}
}
#endif

#endif
