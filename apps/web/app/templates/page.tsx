import { templateCatalog } from "../../lib/chain";

export default function TemplatesPage() { return <main><h1>70X 模板</h1><ul>{templateCatalog.map((template) => <li key={template.id}><strong>{template.label}</strong><span> · v1 · {template.kind}</span></li>)}</ul></main>; }
