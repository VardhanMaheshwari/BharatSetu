const {Connection, PublicKey} = require('@solana/web3.js');
const conn = new Connection('https://api.devnet.solana.com');
const pubkey = new PublicKey('892ufnCLcrz7fMiSbWdNa8dQ6seRno6n47gtpvHNQmFU');

conn.getSignaturesForAddress(pubkey, {limit: 50}).then(async sigs => {
  sigs.reverse();
  for (const s of sigs) {
    const tx = await conn.getTransaction(s.signature, {maxSupportedTransactionVersion: 0});
    if (!tx || !tx.meta) continue;
    const logStr = tx.meta.logMessages ? tx.meta.logMessages.join(' ') : '';
    if (logStr.includes('InitializeMint')) {
      console.log('Mint tx found:', s.signature);
      const accounts = tx.transaction.message.accountKeys.map(k => k.pubkey ? k.pubkey.toBase58() : k.toBase58());
      console.log('Accounts in tx:', accounts);
      // Usually the mint is the second account in the array (index 1), because payer is index 0.
      console.log('Possible Mint Address:', accounts[1]);
    }
  }
}).catch(console.error);
