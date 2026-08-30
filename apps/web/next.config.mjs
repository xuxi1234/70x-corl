/** @type {import('next').NextConfig} */
const config = {
  output: "standalone",
  transpilePackages: ["@70x/indexer", "@70x/protocol"],
};

export default config;
