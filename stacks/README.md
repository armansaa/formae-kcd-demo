# stacks/

Satu file per stack formae. File di sini **dihasilkan** oleh
`formae extract --desired --query 'stack:<nama>'`, bukan ditulis tangan: bot `reality-sync`
menimpanya setiap kali drift diserap.

Isi awal (sekali, dari laptop yang terhubung ke agent):

```bash
formae extract --desired --yes --profile gke-kcd \
  --query 'stack:kcd-demo-app' stacks/kcd-demo-app.pkl
```
