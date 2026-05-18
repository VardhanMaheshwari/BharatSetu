const fs = require('fs');
const path = require('path');
const bs58 = require('bs58');

const envPath = path.resolve(__dirname, '../../.env');
const envContent = fs.readFileSync(envPath, 'utf8');

const match = envContent.match(/SOLANA_RELAYER=(0x)?([a-zA-Z0-9]+)/);
if (match) {
  const b58 = match[2];
  const decode = bs58.decode || bs58.default.decode;
  const decoded = decode(b58);
  const arr = Array.from(decoded);
  const outPath = path.resolve(__dirname, 'relayer.json');
  fs.writeFileSync(outPath, JSON.stringify(arr));
  console.log(`Key saved to ${outPath}`);
  
  let newEnv = envContent.replace(/SOLANA_RELAYER=.*/, `SOLANA_RELAYER_KEYPAIR=${outPath}`);
  fs.writeFileSync(envPath, newEnv);
  console.log(`.env updated with SOLANA_RELAYER_KEYPAIR`);
} else {
  console.error('SOLANA_RELAYER not found in .env');
  process.exit(1);
}
