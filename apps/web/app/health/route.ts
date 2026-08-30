const releaseCommit = () => process.env.CHAIN97_RELEASE_COMMIT?.trim() || process.env.VERCEL_GIT_COMMIT_SHA?.trim();

export async function GET() {
  const commit = releaseCommit();
  if (!commit || !/^[0-9a-f]{40}$/i.test(commit)) {
    return Response.json({ error: "RELEASE_COMMIT_NOT_CONFIGURED" }, { status: 503 });
  }
  return Response.json({ chainId: 97, releaseCommit: commit.toLowerCase() });
}
