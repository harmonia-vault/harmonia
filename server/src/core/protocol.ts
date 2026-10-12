// 协议版本与服务端版本。服务端版本只写在 package.json 里，发布前改成要发布的版本号（发布流水线会核对）。
import pkg from "../../package.json";

export const PROTOCOL = 1;
export const VERSION: string = pkg.version;
