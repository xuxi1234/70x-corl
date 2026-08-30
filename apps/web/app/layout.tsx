import type { ReactNode } from "react";
import { SiteShell } from "../components/site-shell";
import "./styles.css";

export default function RootLayout({ children }: { children: ReactNode }) {
  return <html lang="zh-CN"><head><meta name="viewport" content="width=device-width, initial-scale=1" /></head><body><SiteShell>{children}</SiteShell></body></html>;
}
