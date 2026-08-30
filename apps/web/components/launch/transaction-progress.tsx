export type TransactionStage = "idle" | "wallet" | "submitted" | "confirmed" | "error";

export function TransactionProgress({ stage, hash, onRetry }: { stage: TransactionStage; hash?: string; onRetry?: () => void }) {
  const message: Record<TransactionStage, string> = {
    idle: "等待配置复核",
    wallet: "等待钱包确认",
    submitted: "交易已提交，等待区块确认",
    confirmed: "交易已确认",
    error: "交易失败，配置与资金未被修改",
  };
  return <section className={`status-panel ${stage === "error" ? "warning" : ""}`} role="status" aria-live="polite">
    <strong>{message[stage]}</strong>
    {hash ? <p className="hash">{hash}</p> : null}
    {stage === "error" && onRetry ? <button type="button" onClick={onRetry}>重新尝试</button> : null}
  </section>;
}
