// 松萝鸿蒙输入法：InputMethodExtensionAbility（ArkTS）
// 与 macOS/Android/iOS 端行为约定一致：空格首选、数字选词、Esc 取消、回车原样。
// 内核经 NAPI 模块 liana 调用（同一份 liana.h C ABI）。
import inputMethod from '@ohos.inputMethod';
import liana from 'libliana.so';

const TAG = 'LianaIME';
const MODES: string[] = ['pinyin', 'en'];

export default class LianaIME extends inputMethod.InputMethodExtensionAbility {
  private session: number = 0;
  private modeIdx: number = 0;
  private panel: inputMethod.Panel | null = null;

  onCreate(): void {
    // 词典：随包 rawfile/base.ifd 首启复制到应用沙箱
    let dictPath: string | null = null;
    try {
      let ctx = this.context;
      let target = ctx.filesDir + '/base.ifd';
      if (!fs.accessSync(target)) {
        let raw = ctx.resourceManager.getRawFileContent('base.ifd');
        fs.writeSync(target, raw.buffer);
      }
      dictPath = target;
    } catch (e) {
      // 词典缺失回退内核内置词典
    }
    this.session = dictPath ? liana.newWithDict('pinyin', dictPath) : liana.new('pinyin');
    this.createPanel();
  }

  onDestroy(): void {
    if (this.session) {
      liana.free(this.session);
      this.session = 0;
    }
    if (this.panel) {
      this.panel.destroy();
      this.panel = null;
    }
  }

  // ---- 键盘面板（ArkUI 程序化布局） ----
  private createPanel(): void {
    this.panel = inputMethod.createPanel(this.context, inputMethod.PanelType.SOFT_KEYBOARD);
    let root = new ColumnComponent(this); // 见 LianaKeyboard.ets 导出的组件
    this.panel.setUiContent(root);
    let inputSetting: inputMethod.InputMethodSetting = this.getInputMethodSetting();
    inputSetting.listInputMethodSubtype();
  }

  onInputStart(): void {
    // 会话开始：重置组合态
    liana.clear(this.session);
  }

  // ---- 供键盘组件回调 ----
  public feed(ch: string): string {
    if (liana.feed(this.session, ch)) {
      return liana.compositionJson(this.session);
    }
    return '{}';
  }

  public backspace(): string {
    liana.backspace(this.session);
    return liana.compositionJson(this.session);
  }

  public select(index: number): string {
    let text = liana.select(this.session, index);
    return text ? text : '';
  }

  public space(): string {
    let comp = JSON.parse(liana.compositionJson(this.session));
    if (comp.candidates && comp.candidates.length > 0) {
      let text = liana.select(this.session, 0);
      return text ? text : ' ';
    }
    return ' ';
  }

  public enter(): string {
    return liana.commitRaw(this.session) ?? '';
  }

  public toggleMode(): string {
    this.modeIdx = (this.modeIdx + 1) % MODES.length;
    liana.setMode(this.session, MODES[this.modeIdx]);
    liana.clear(this.session);
    return MODES[this.modeIdx];
  }
}

import fs from '@ohos.file.fs';