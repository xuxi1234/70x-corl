export default function ProjectPage({ params }: { params: { address: string } }) {
  return <main data-mobile="stack"><p>CHAIN 97 / PROJECT</p><h1>项目详情</h1><p className="hash">{params.address}</p><section className="status-panel warning" role="status" aria-live="polite">RPC 一致性：等待索引与双 RPC 比对；不一致时 Verified 标识自动禁用。</section><dl><dt>模板版本</dt><dd>v1</dd><dt>配置哈希</dt><dd className="hash">直接 RPC 读取</dd><dt>验证状态</dt><dd>Pending</dd></dl><button type="button">重试读取</button></main>;
}
