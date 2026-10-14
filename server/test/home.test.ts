import { describe, expect, it } from "vitest";
import { homePage } from "../src/core/home";
import { VERSION } from "../src/core/protocol";
import { route } from "../src/core/router";
import { TestServer } from "./helpers";

const open = (s: TestServer, method: string, url: string) => route(new Request(url, { method }), s.backend(), "198.51.100.7");

describe("实例首页", () => {
  it("浏览器打开服务器地址时显示首页，并带上这台服务器的地址", async () => {
    const res = await open(new TestServer(), "GET", "http://localhost:8787/");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
    const html = await res.text();
    expect(html).toContain("<code data-copy>http://localhost:8787</code>");
    expect(html).toContain("harmonia login http://localhost:8787</code>");
    expect(html).toMatch(/<svg viewBox="-3 -3 \d+ \d+" class="qr"/);
  });

  it("接入电脑一步在安装命令之前给出各个系统通用的 AI 助手提示词，带上这台服务器的地址", async () => {
    const html = await (await homePage("https://vault.example.com")).text();
    const prompt = html.match(/<p class="prompt" data-copy>(.*?)<\/p>/)?.[1] ?? "";
    expect(prompt).toMatch(/^Harmonia（和弦，https:\/\/vault\.example\.com）是用户部署的环境变量同步服务/);
    expect(prompt).toContain("不需要用户把 Key 贴进对话。请在这台电脑上安装 Harmonia 命令行：");
    expect(prompt).not.toContain("我");
    expect(prompt).toContain("install.sh | HARMONIA_YES=0 sh；");
    expect(prompt).toContain("$env:HARMONIA_YES = &#39;0&#39;; irm https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.ps1 | iex。");
    expect(prompt).toContain("运行 harmonia skill，按输出的说明接入服务器 https://vault.example.com（邮箱和配对码向用户询问），并询问用户是否开启 Shell 集成和后台服务。");
    expect(html.match(/class="prompt"/g)).toHaveLength(1);
    expect(html.indexOf('class="addr"')).toBeLessThan(html.indexOf('class="ai"'));
    expect(html.indexOf('class="ai"')).toBeLessThan(html.indexOf('class="term"'));
  });

  it("页头显示服务端版本", async () => {
    const html = await (await homePage("https://vault.example.com")).text();
    expect(html).toContain(`<div class="status"><i></i>运行中<span title="服务端版本">v${VERSION}</span></div>`);
  });

  it("服务器地址、提示词和每条命令都有复制按钮", async () => {
    const html = await (await homePage("https://vault.example.com")).text();
    expect(html.match(/ data-copy>/g)).toHaveLength(5);
    expect(html).toContain('<code data-copy>https://vault.example.com</code>');
    expect(html).toContain('<code data-copy>harmonia login https://vault.example.com</code>');
  });

  it("只带一段内嵌的复制脚本，内容安全策略按哈希放行，不加载外部资源", async () => {
    const res = await open(new TestServer(), "GET", "http://localhost/");
    const csp = res.headers.get("content-security-policy")!;
    expect(csp).toContain("default-src 'none'");
    const html = await res.text();
    const scripts = [...html.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/g)];
    expect(scripts).toHaveLength(1);
    expect(scripts[0]![1]).toBe("");
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(scripts[0]![2]));
    expect(csp).toContain(`script-src 'sha256-${Buffer.from(digest).toString("base64")}'`);
    expect(html).not.toMatch(/<img|<iframe|<form|@import|url\(\s*["']?https?:/i);
    expect([...html.matchAll(/(?:src|href)="([^"]+)"/g)].map((m) => m[1]).filter((u) => !/^(https:\/\/github\.com\/harmonia-vault\/|data:image\/svg\+xml,)/.test(u!))).toEqual([]);
  });

  it("地址里的特殊字符不会变成页面内容", async () => {
    const html = await (await homePage(`https://a"><b>&'`)).text();
    expect(html).toContain("https://a&quot;&gt;&lt;b&gt;&amp;&#39;");
    expect(html).not.toContain(`a"><b>`);
  });

  it("只有 GET 和 HEAD 访问根路径才是首页，其他照旧", async () => {
    const s = new TestServer();
    expect((await open(s, "HEAD", "http://localhost/")).status).toBe(200);
    expect((await open(s, "POST", "http://localhost/")).status).toBe(404);
    expect((await open(s, "GET", "http://localhost/index.html")).status).toBe(404);
    expect((await open(s, "GET", "http://example.com/")).status).toBe(400);
  });

  it("受入口总量限制", async () => {
    const s = new TestServer();
    s.entryLimit = async () => false;
    expect((await open(s, "GET", "http://localhost/")).status).toBe(429);
  });
});
