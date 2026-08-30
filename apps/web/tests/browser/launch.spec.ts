import { expect, test } from "@playwright/test";

const templates = [
  ["STANDARD", "标准 Mint 发射", "Mint 份数"],
  ["TIME_WEIGHTED", "持币时长加权分红", "最高权重倍数（BP）"],
  ["LP_REWARDS", "LP 持有者分红", "LP 代币地址"],
  ["HOLDER_DEAD", "持币/黑洞分红", "黑洞分红（BP）"],
  ["AUTO_BUYBACK", "自动回购本币", "回购触发阈值"],
  ["TIMED_BUYBACK", "定时回购本币", "回购间隔秒数"],
  ["EXTERNAL_BURN", "回购销毁外部币", "外部销毁代币"],
  ["FINANCE_EXIT", "理财退本", "理财支持代币"],
  ["LAUNCH_LIMIT", "分时段持仓限制", "限制窗口分钟数组"],
  ["WHITELIST", "白名单 Mint", "初始白名单根"],
  ["FLAP_JOINT", "Flap 联合发射", "BNB 目标（wei）"],
] as const;

async function fillValidStandard(page: import("@playwright/test").Page) {
  await page.getByLabel("代币名称").fill("Seventy X");
  await page.getByLabel("代币符号").fill("70X");
  await page.getByLabel("总量").fill("1000000000");
  await page.getByLabel("接收地址").fill("0x1000000000000000000000000000000000000001");
  await page.getByLabel("Mint 份数").fill("10");
  await page.getByLabel("每份价格（wei）").fill("100000000000000");
  await page.getByLabel("认领代币占比（BP）").fill("2000");
  await page.getByLabel("最小流动性输出").fill("1");
  await page.getByLabel("买税 BP").fill("0");
  await page.getByLabel("卖税 BP").fill("0");
  for (const field of ["流动性分配 BP", "营销分配 BP", "分红分配 BP", "回购分配 BP"]) {
    await page.getByLabel(field).fill("0");
  }
}

test("all eleven protocol templates expose their own browser fields", async ({ page }) => {
  await page.goto("/launch");
  const selector = page.getByLabel("发射模板");
  await expect(selector.locator("option")).toHaveCount(11);
  for (const [id, label, field] of templates) {
    await selector.selectOption(id);
    await expect(page.getByRole("heading", { name: label })).toBeVisible();
    await expect(page.getByLabel(field)).toBeVisible();
  }
});

test("valid standard configuration reaches an encoded review without broadcasting", async ({ page }) => {
  await page.goto("/launch");
  await fillValidStandard(page);
  await page.getByRole("button", { name: "校验配置并复核交易" }).click();
  await expect(page.getByRole("status")).toContainText("配置校验通过");
  await expect(page.getByTestId("config-hash")).toHaveText(/^0x[0-9a-f]{64}$/);
  await expect(page.getByText("尚未广播交易")).toBeVisible();
});

test("invalid tax is rejected before the review transaction exists", async ({ page }) => {
  await page.goto("/launch");
  await fillValidStandard(page);
  await page.getByLabel("买税 BP").fill("1001");
  await page.getByRole("button", { name: "校验配置并复核交易" }).click();
  await expect(page.locator("section[role='alert']")).toContainText("配置无效");
  await expect(page.getByTestId("config-hash")).toHaveCount(0);
});

test("project detail remains readable and recoverable on a mobile viewport", async ({ page }, testInfo) => {
  test.skip(!testInfo.project.name.startsWith("mobile"), "mobile acceptance only");
  await page.goto("/project/0x1000000000000000000000000000000000000001");
  await expect(page.getByRole("status")).toContainText("RPC 一致性");
  await expect(page.getByRole("button", { name: "重试读取" })).toBeVisible();
  const bodyWidth = await page.locator("body").evaluate((body) => body.scrollWidth);
  const viewportWidth = page.viewportSize()?.width;
  expect(bodyWidth).toBeLessThanOrEqual(viewportWidth ?? bodyWidth);
});

test("release health endpoint is bound to Chain 97 and one exact commit", async ({ request }) => {
  const response = await request.get("/health");
  expect(response.ok()).toBe(true);
  expect(await response.json()).toEqual({
    chainId: 97,
    releaseCommit: "3188a29ed010089df2ce9b99a2cb09837096c9be",
  });
});
