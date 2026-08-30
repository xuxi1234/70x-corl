import type { ReactNode } from "react";

export function SiteShell({ children }: { children: ReactNode }) {
  return <>
    <header className="site-header"><a className="brand" href="/">70<span>X</span></a><nav className="site-nav" aria-label="主导航"><a href="/launch">部署</a><a href="/templates">模板</a><a href="/flap-launch">Flap</a></nav></header>
    {children}
  </>;
}
