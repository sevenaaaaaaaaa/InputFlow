/* InputFlow C ABI v1
 *
 * 约定：
 * - 所有返回的 char* 由调用方用 inputflow_free_string 释放；
 * - 所有函数在内部捕获 panic，不会跨 FFI 边界展开；
 * - 组合态以 JSON 返回，字段见 inputflow_composition_json 注释。
 */
#ifndef INPUTFLOW_H
#define INPUTFLOW_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct InputFlowSession InputFlowSession;
typedef struct InputFlowAppMode InputFlowAppMode;

/* 创建会话。mode: "pinyin" | "flypy" | "mspy" | "zrm" | "en" | "ja"；
 * 传 NULL 时使用内置词典与拼音模式。 */
InputFlowSession *inputflow_new(const char *mode);

/* 使用外部 IFD1 词典文件创建会话；失败时回退内置词典。 */
InputFlowSession *inputflow_new_with_dict(const char *mode, const char *dict_path);

void inputflow_free(InputFlowSession *session);

/* 输入一个字符（UTF-8，单个码点）。返回 1 表示被接受。 */
int32_t inputflow_feed(InputFlowSession *session, const char *utf8_char);

int32_t inputflow_backspace(InputFlowSession *session);

void inputflow_clear(InputFlowSession *session);

/* 切换模式，返回 1 表示成功。 */
int32_t inputflow_set_mode(InputFlowSession *session, const char *mode);

/* 当前模式 id。 */
char *inputflow_mode(InputFlowSession *session);

/* 简繁显示：on 非 0 时候选转成繁体（学习与重排仍以简体为准）。 */
int32_t inputflow_set_traditional(InputFlowSession *session, int32_t on);
int32_t inputflow_traditional(InputFlowSession *session);

/* 组合态 JSON：
 * {"raw":"nihao","preedit":"ni hao","candidates":[
 *    {"text":"你好","consumed":5,"kind":"sentence","comment":"ni hao"}]}
 */
char *inputflow_composition_json(InputFlowSession *session);

/* 选择候选上屏，返回提交文本；索引越界返回 NULL。 */
char *inputflow_select(InputFlowSession *session, uint32_t index);

/* 原样上屏当前缓冲，返回提交文本；缓冲为空返回 NULL。 */
char *inputflow_commit_raw(InputFlowSession *session);

/* 用户词学习：导入/导出 TSV（词\t次数），供加密存储层使用。 */
char *inputflow_user_export(InputFlowSession *session);

int32_t inputflow_user_import(InputFlowSession *session, const char *tsv);

/* 备份与恢复：导出带版本头与 CRC32 的明文包（前端负责加密落盘、明文导出二次确认）；
 * 导入时 merge 非 0 表示同名条目取较大次数，返回条目数，失败返回 -1。 */
char *inputflow_backup_export(InputFlowSession *session);
int32_t inputflow_backup_import(InputFlowSession *session, const char *text, int32_t merge);

void inputflow_free_string(char *s);

/* 本地 AI 增强（零云 API）：模型目录与内存推荐，JSON 由调用方释放。 */
char *inputflow_ai_catalog_json(void);
char *inputflow_ai_recommend_json(uint64_t total_ram_mb);

/* 每应用中英模式记忆：本地统计模型，只存 bundle id 与票数，无按键内容。
 * 句柄独立于输入会话，整个进程共享一份；持久化由前端负责。 */
InputFlowAppMode *inputflow_app_mode_new(void);
void inputflow_app_mode_free(InputFlowAppMode *memory);

/* 记录一次信号：zh 非 0 为中文侧；strong 非 0 为手动切换（Shift/菜单），
 * 否则为上屏弱信号；now 为 Unix 秒。返回 1 表示已记录。 */
int32_t inputflow_app_mode_observe(InputFlowAppMode *memory, const char *app_id,
                                   int32_t zh, int32_t strong, uint64_t now);

/* 该应用该用中文还是英文？1 = 中文，0 = 英文，-1 = 样本不足不干预。 */
int32_t inputflow_app_mode_decide(InputFlowAppMode *memory, const char *app_id,
                                  uint64_t now);

/* 忘记单个应用的偏好。返回 1 表示存在过并已删除。 */
int32_t inputflow_app_mode_forget(InputFlowAppMode *memory, const char *app_id);

/* 清空全部学习结果（关闭学习开关时调用，不留数据）。 */
void inputflow_app_mode_forget_all(InputFlowAppMode *memory);

/* 学习结果 TSV 导出/导入（应用\t中文票\t英文票\t上屏天\t上屏票\t更新时间）。 */
char *inputflow_app_mode_export(InputFlowAppMode *memory);
int32_t inputflow_app_mode_import(InputFlowAppMode *memory, const char *tsv);

/* 输入统计总结（全为计数，零内容）：返回指标 JSON，由调用方释放。 */
char *inputflow_stats_digest_json(uint64_t chars, uint64_t keys, uint64_t deletes,
                                  uint64_t enters, uint64_t saved_keys,
                                  uint64_t voice_chars, uint64_t active_secs,
                                  uint64_t stare_max_secs);

/* 插件包扫描（皮肤/桌宠/词典声明式数据包，零代码执行）：
 * 返回目录 JSON {"packs":[...],"errors":[...]}，由调用方释放。 */
char *inputflow_plugin_scan_json(const char *dir);

/* 版本字符串（静态，勿释放）。 */
const char *inputflow_version(void);

#ifdef __cplusplus
}
#endif

#endif /* INPUTFLOW_H */
