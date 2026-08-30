import { templateCatalog } from "../../lib/chain";

export function LaunchWizard({ mode = "all" }: { mode?: "all" | "flap" }) {
  const templates = mode === "flap" ? templateCatalog.filter((template) => template.id === "FLAP") : templateCatalog;
  return <form aria-label="70X 部署向导" className="launch-wizard">
    <label>发射模板<select name="templateId" defaultValue={templates[0]?.id}>{templates.map((template) => <option key={template.id} value={template.id}>{template.label}</option>)}</select></label>
    <label>代币名称<input name="name" required maxLength={64} /></label>
    <label>代币符号<input name="symbol" required maxLength={16} /></label>
    <label>总量<input name="supply" type="number" min="1" max="100000000000" required /></label>
    {mode === "flap" ? <label>BNB 目标<input name="goalBnb" type="number" min="2" max="16" required /></label> : null}
    <fieldset><legend>税费与分配</legend><label>买税 BP<input name="buyTaxBps" type="number" min="0" max="1000" /></label><label>卖税 BP<input name="sellTaxBps" type="number" min={mode === "flap" ? 100 : 0} max="1000" /></label></fieldset>
    <section aria-label="部署复核"><strong>部署费：0.005 BNB</strong><p>浏览器仅使用协议共享 schema 编码；钱包确认后才会提交。</p></section>
    <button type="submit">复核并连接钱包</button>
  </form>;
}
