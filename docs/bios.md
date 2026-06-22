# OptiPlex 3060 BIOS prep (one-time, manual)

Do before/at install — easy to forget later.

- [ ] **Virtualization → Enabled** (VT-x)
- [ ] **VT for Direct I/O → Enabled** (VT-d / IOMMU) — for any future VM passthrough
- [ ] **AC Recovery → On** (or "Last Power State") — headless box must auto-boot after a power blip
- [ ] **Boot mode → UEFI**, **Secure Boot → Off** (Proxmox installer)
- [ ] **Integrated graphics → Enabled / Auto** — never disable; QuickSync is the whole iGPU plan
- [ ] **Fast Boot → Thorough** (optional, more reliable cold boots)
- [ ] **Update the Dell BIOS** to latest
- [ ] Confirm RAM (16GB is fine for this stack; 32GB only when expanding)
