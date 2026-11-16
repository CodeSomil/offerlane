// A system notification (the Windows app's toast) for news while Offerlane is in the background; nothing in a browser.
import { platform } from "./platform.js";

export function notify(title: string, body: string) {
  if (!platform.notify || document.hasFocus()) return;
  platform.notify(title, body).catch(() => {});  // a notification that can't be shown is not an error
}
