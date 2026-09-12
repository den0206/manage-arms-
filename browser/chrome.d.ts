/**
 * 使う分だけの Chrome 拡張 API。`@types/chrome` は入れない —
 * 必要になるまで依存を増やさない（CLAUDE.md「配布・依存管理」）。
 */
declare namespace chrome {
  namespace runtime {
    const id: string;
    function getURL(path: string): string;
    function sendMessage<T = unknown, R = unknown>(message: T): Promise<R>;
    const onMessage: {
      addListener(handler: (
        message: unknown,
        sender: { tab?: { id?: number }; url?: string },
        respond: (response?: unknown) => void,
      ) => boolean | void): void;
    };
  }
  namespace tabs {
    function create(options: { url: string }): Promise<{ id?: number }>;
    function sendMessage<T = unknown>(tabId: number, message: T): Promise<unknown>;
  }
  namespace storage {
    interface Area {
      get<T extends Record<string, unknown>>(defaults: T): Promise<T>;
      set(items: Record<string, unknown>): Promise<void>;
    }
    const local: Area;
  }
  namespace i18n {
    function getMessage(key: string, substitutions?: string | string[]): string;
  }
  namespace action {
    function openPopup(): Promise<void>;
    const onClicked: { addListener(handler: () => void): void };
  }
}
