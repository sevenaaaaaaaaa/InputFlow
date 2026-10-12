/* Liana FFI 冒烟测试（阶段 0 跨平台就绪度验证）
 *
 * 用 C 直接调用 liana.h——与未来 Windows/Linux/Android/iOS/鸿蒙外壳
 * 完全同构的接入路径。任何平台只要这个程序能编译运行，内核就算就绪。
 *
 * 构建（宿主机）：
 *   cargo build -p liana-ffi --release
 *   cc tools/ffi_smoke.c -I crates/ffi/include \
 *      target/release/libliana_ffi.a -o /tmp/liana_ffi_smoke
 * 交叉编译时把静态库换成对应 target 目录的产物即可。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "liana.h"

static int failures = 0;

#define CHECK(cond, msg)                                                    \
    do {                                                                    \
        if (cond) { printf("  ✓ %s\n", msg); }                              \
        else      { printf("  ✗ %s\n", msg); failures++; }                  \
    } while (0)

/* 逐码点喂入 UTF-8 字符串 */
static void feed_all(LianaSession *s, const char *text) {
    const unsigned char *p = (const unsigned char *)text;
    char buf[5];
    while (*p) {
        int len = (*p < 0x80) ? 1 : (*p >> 5) == 0x6 ? 2 : (*p >> 4) == 0xE ? 3 : 4;
        memcpy(buf, p, len);
        buf[len] = '\0';
        liana_feed(s, buf);
        p += len;
    }
}

int main(void) {
    printf("== Liana FFI 冒烟（版本 %s）==\n", liana_version());

    /* 1. 会话生命周期 */
    LianaSession *s = liana_new("pinyin");
    CHECK(s != NULL, "liana_new(\"pinyin\") 返回会话");

    /* 2. 拼音整句：nihao → 应有候选，首选应为高频词 */
    feed_all(s, "nihao");
    char *json = liana_composition_json(s);
    CHECK(json != NULL && strstr(json, "candidates") != NULL, "nihao 产生候选 JSON");
    CHECK(json != NULL && strstr(json, "\"raw\":\"nihao\"") != NULL, "raw 键回显正确");
    char *first_cand = json ? strdup(json) : NULL;
    if (first_cand) printf("    候选样例: %.120s…\n", first_cand);

    /* 3. 选词上屏 */
    char *commit = liana_select(s, 0);
    CHECK(commit != NULL && strlen(commit) > 0, "select(0) 上屏非空");
    if (commit) printf("    上屏: %s\n", commit);

    /* 4. 退格与清空 */
    feed_all(s, "zhong");
    CHECK(liana_backspace(s) == 1, "backspace 被接受");
    liana_clear(s);
    json = liana_composition_json(s);
    CHECK(json != NULL && strstr(json, "\"candidates\":[]") != NULL,
          "clear 后候选为空数组");

    /* 5. 模式切换（五端菜单将复用同一组模式 id） */
    CHECK(liana_set_mode(s, "en") == 1, "切到 en 模式");
    char *mode = liana_mode(s);
    CHECK(mode && strcmp(mode, "en") == 0, "模式回读为 en");
    feed_all(s, "hello");
    json = liana_composition_json(s);
    CHECK(json != NULL && strstr(json, "candidates") != NULL, "en 模式补全产生候选");

    /* 6. 简繁开关 */
    CHECK(liana_set_mode(s, "pinyin") == 1, "切回 pinyin");
    CHECK(liana_set_traditional(s, 1) == 1, "开启繁体显示");
    CHECK(liana_traditional(s) == 1, "繁体状态回读");
    CHECK(liana_set_traditional(s, 0) == 1, "关闭繁体显示");

    /* 7. 外部上屏学习 + 用户词导出/导入（持久化由前端负责，ABI 只管数据） */
    CHECK(liana_record_commit(s, "输入法引擎冒烟测试") == 0, "record_commit 外部学习");
    char *tsv = liana_user_export(s);
    CHECK(tsv != NULL, "user_export 导出 TSV");
    if (tsv) printf("    用户词 TSV: %.80s…\n", tsv);

    /* 8. 备份/恢复闭环 */
    char *backup = liana_backup_export(s);
    CHECK(backup != NULL, "backup_export 产出带 CRC 的明文包");
    if (backup) {
        int n = liana_backup_import(s, backup, 1);
        CHECK(n >= 0, "backup_import 合并回灌");
    }

    /* 9. 应用级中英记忆句柄（独立于会话） */
    LianaAppMode *am = liana_app_mode_new();
    CHECK(am != NULL, "app_mode_new 句柄");
    if (am) {
        CHECK(liana_app_mode_observe(am, "com.test.editor", 1, 1, 1700000000) == 1,
              "observe 记录中文信号");
        liana_app_mode_free(am);
    }

    /* 10. 纯函数入口：术语提炼 / AI 目录 / 插件扫描 */
    char *ext = liana_feed_extract_json("松萝输入法的松萝内核");
    CHECK(ext != NULL && strstr(ext, "松萝") != NULL, "feed_extract 提炼术语");
    char *ai = liana_ai_catalog_json();
    CHECK(ai != NULL, "ai_catalog_json 可用");
    char *plug = liana_plugin_scan_json("/nonexistent-dir");
    CHECK(plug != NULL, "plugin_scan_json 空目录不炸");

    /* 清理 */
    liana_free_string(first_cand ? first_cand : NULL);
    liana_free_string(commit);
    liana_free_string(mode);
    liana_free_string(tsv);
    liana_free_string(backup);
    liana_free_string(ext);
    liana_free_string(ai);
    liana_free_string(plug);
    liana_free(s);

    printf("== 结果：%s（%d 项失败）==\n", failures == 0 ? "全部通过" : "存在失败", failures);
    return failures == 0 ? 0 : 1;
}