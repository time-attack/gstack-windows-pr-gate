# GStack Windows PR gate

This public harness runs the immutable baseline and exact reviewed head of
`garrytan/gstack#2260` on ephemeral GitHub-hosted machines.

- Baseline: `a3259400a366593e0c909dd9ac3e59752efd2488`
- Candidate: `b9fbe4dea9b192d5d6fe6814bc558f89ef41dde7`
- Windows: Windows 11 ARM64 in both plain and space-containing paths, plus a
  Windows Server 2025 x64 control
- Non-Windows control: Ubuntu

The workflow is manual-only. It uses no repository secrets, clones only public
sources, pins third-party actions by commit, and uploads its evidence logs.

