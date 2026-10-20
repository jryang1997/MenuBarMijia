import { Window } from "happy-dom";

export function installWindow(dom: Window): void {
  Object.defineProperties(globalThis, {
    window: { value: dom, configurable: true },
    document: { value: dom.document, configurable: true },
    localStorage: { value: dom.localStorage, configurable: true },
    Event: { value: dom.Event, configurable: true },
  });
}

installWindow(new Window());
