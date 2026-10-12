import { describe, expect, it } from "vitest";
import { homePage } from "../src/core/home";
import { route } from "../src/core/router";
import { TestServer } from "./helpers";

const open = (s: TestServer, method: string, url: string) => route(new Request(url, { method }), s.backend(), "198.51.100.7");

describe("实例首页", () => {
  it("浏览器打开服务器地址时显示首页，并带上这台服务器的地址", async () => {
    const res = await open(new TestServer(), "GET", "http://localhost:8787/");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
    const html = await res.text();
    expect(html).toContain("<code>http://localhost:8787</code>");
    expect(html).toContain("harmonia login http://localhost:8787</code>");
    expect(html).toMatch(/<svg viewBox="-3 -3 \d+ \d+" class="qr"/);
  });

  it("不带脚本，不加载外部资源", async () => {
    const res = await open(new TestServer(), "GET", "http://localhost/");
    expect(res.headers.get("content-security-policy")).toContain("default-src 'none'");
    const html = await res.text();
    expect(html).not.toMatch(/<script|<img|<iframe|<form|@import|url\(\s*["']?https?:/i);
    expect([...html.matchAll(/(?:src|href)="([^"]+)"/g)].map((m) => m[1]).filter((u) => !/^(https:\/\/github\.com\/harmonia-vault\/|data:image\/svg\+xml,)/.test(u!))).toEqual([]);
  });

  it("地址里的特殊字符不会变成页面内容", async () => {
    const html = await homePage(`https://a"><b>&'`).text();
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
