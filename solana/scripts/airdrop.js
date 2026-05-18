const { Connection, PublicKey, LAMPORTS_PER_SOL } = require('@solana/web3.js');
const conn = new Connection('https://api.devnet.solana.com', 'confirmed');
const pubkey = new PublicKey('6z8KJbNDwQTwpnTyH9uZjM3tkGSKXuWnv72KQDiQn9LC');
conn.requestAirdrop(pubkey, 0.5 * LAMPORTS_PER_SOL)
  .then(sig => {
    console.log('Airdrop tx:', sig);
    return conn.confirmTransaction(sig);
  })
  .then(() => {
    console.log('Airdrop confirmed');
  })
  .catch(err => {
    console.error('Airdrop failed:', err);
    process.exit(1);
  });
