"use client";

import { templateFields, type TemplateId } from "@70x/protocol";
import { useState } from "react";
import { templateCatalog } from "../../lib/chain";

export function LaunchWizard({
  mode = "all",
  initialTemplateId,
}: {
  mode?: "all" | "flap";
  initialTemplateId?: TemplateId;
}) {
  const templates = mode === "flap"
    ? templateCatalog.filter((template) => template.id === "FLAP_JOINT")
    : templateCatalog;
  const firstTemplate = initialTemplateId && templates.some(({ id }) => id === initialTemplateId)
    ? initialTemplateId
    : templates[0]?.id ?? "STANDARD";
  const [templateId, setTemplateId] = useState<TemplateId>(firstTemplate);

  return <form aria-label="70X 部署向导" className="launch-wizard">
    <header className="wizard-heading"><span>01 / 配置</span><h2>{templates.find(({ id }) => id === templateId)?.label}</h2></header>
    <label>发射模板<select
      name="templateId"
      value={templateId}
      onChange={(event) => setTemplateId(event.target.value as TemplateId)}
    >{templates.map((template) => <option key={template.id} value={template.id}>{template.label}</option>)}</select></label>
    <div className="field-grid">
      <label>代币名称<input name="name" required /></label>
      <label>代币符号<input name="symbol" required /></label>
      <label>总量<input name="supply" inputMode="numeric" required /></label>
      <label>接收地址<input name="receiver" inputMode="text" required /></label>
    </div>
    <fieldset><legend>模板专用参数</legend><div className="field-grid">
      {templateFields[templateId].map((field) => <label key={field.path}>{field.label}<input
        name={`templateConfig.${field.path}`}
        type={field.input === "number" ? "number" : "text"}
        inputMode={field.input === "number" ? "numeric" : "text"}
        required
      /></label>)}
    </div></fieldset>
    <fieldset><legend>税费与分配</legend><div className="field-grid">
      <label>买税 BP<input name="buyTaxBps" inputMode="numeric" /></label>
      <label>卖税 BP<input name="sellTaxBps" inputMode="numeric" /></label>
      <label>流动性分配 BP<input name="allocationBps.0" inputMode="numeric" /></label>
      <label>营销分配 BP<input name="allocationBps.1" inputMode="numeric" /></label>
      <label>分红分配 BP<input name="allocationBps.2" inputMode="numeric" /></label>
      <label>回购分配 BP<input name="allocationBps.3" inputMode="numeric" /></label>
    </div></fieldset>
    <section aria-label="部署复核" className="review-card"><span>固定平台费</span><strong>0.005 BNB</strong><p>所有字段由协议共享 schema 校验并编码；钱包确认前不会提交交易。</p></section>
    <button type="submit">校验配置并复核交易</button>
  </form>;
}
