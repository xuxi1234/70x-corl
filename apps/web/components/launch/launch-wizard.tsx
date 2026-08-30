"use client";

import { templateFields, type TemplateId } from "@70x/protocol";
import { useState, type FormEvent } from "react";
import { buildLaunchReview, templateCatalog } from "../../lib/chain";

const numericPaths = new Set([
  "totalShares", "claimTokenBps", "launch.totalShares", "launch.claimTokenBps",
  "rewards.maxMultiplierBps", "rewards.growthDuration", "buyback.maxSlippageBps", "buyback.interval",
]);

function setNested(target: Record<string, unknown>, path: string, value: unknown): void {
  const parts = path.split(".");
  let current = target;
  for (const part of parts.slice(0, -1)) {
    const next = current[part];
    if (!next || typeof next !== "object" || Array.isArray(next)) current[part] = {};
    current = current[part] as Record<string, unknown>;
  }
  current[parts.at(-1)!] = value;
}

function parseTemplateValue(path: string, value: string, input: "text" | "number"): unknown {
  if (path === "durationsMinutes" || path === "maximumWalletBps") {
    return value.split(",").map((item) => Number(item.trim()));
  }
  if (input === "number" && numericPaths.has(path)) return Number(value);
  return value;
}

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
  const [reviewHash, setReviewHash] = useState<string>();
  const [error, setError] = useState<string>();

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setReviewHash(undefined);
    setError(undefined);
    const data = new FormData(event.currentTarget);
    const templateConfig: Record<string, unknown> = {};
    for (const field of templateFields[templateId]) {
      setNested(templateConfig, field.path, parseTemplateValue(
        field.path,
        String(data.get(`templateConfig.${field.path}`) ?? ""),
        field.input,
      ));
    }
    try {
      const review = buildLaunchReview({
        templateId,
        version: 1,
        name: String(data.get("name") ?? ""),
        symbol: String(data.get("symbol") ?? ""),
        supply: String(data.get("supply") ?? ""),
        receiver: String(data.get("receiver") ?? ""),
        buyTaxBps: Number(data.get("buyTaxBps") ?? 0),
        sellTaxBps: Number(data.get("sellTaxBps") ?? 0),
        rewardToken: "0x0000000000000000000000000000000000000000",
        rewardThreshold: "0",
        lpMode: 0,
        allocationBps: [0, 1, 2, 3].map((index) => Number(data.get(`allocationBps.${index}`) ?? 0)) as [number, number, number, number],
        metadataHash: `0x${"00".repeat(32)}`,
        templateConfig,
      });
      setReviewHash(review.configHash);
    } catch {
      setError("配置无效：请检查必填字段、税率、分配和模板参数边界。");
    }
  }

  return <form aria-label="70X 部署向导" className="launch-wizard" noValidate onSubmit={submit}>
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
    {error ? <section role="alert" className="review-card error">{error}</section> : null}
    {reviewHash ? <section role="status" className="review-card"><strong>配置校验通过</strong><span>配置哈希</span><code className="hash" data-testid="config-hash">{reviewHash}</code><p>尚未广播交易</p></section> : null}
    <button type="submit">校验配置并复核交易</button>
  </form>;
}
