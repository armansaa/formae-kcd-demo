# stacks/

One file per formae stack. These files are **generated**, not written by hand: the
`reality-sync` bot overwrites them every time it absorbs drift.

To regenerate one from a laptop connected to the agent:

```bash
formae extract --desired --yes --profile gke-kcd \
  --query 'stack:kcd-demo-app' stacks/kcd-demo-app.pkl
```
