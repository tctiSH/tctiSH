<!--
Thanks for the contribution. Changes to the emulator itself go to the QEMU fork before getting used
here (https://github.com/tctiSH/qemu). A pull request here then moves the submodule to the commit
that lands there.
-->

## Description

<!-- What the change does and why it's needed. Mention if it fixes an issue using `Closes #123`. -->

## How the Change Was Verified

<!--
What CI checks is rarely sufficient, so please describe what you did to verify the correctness of
the change yourself.
-->

- [ ] CI passes (it runs `make lint` and `make check-images`)
- [ ] Built with `make build`
- [ ] Run on a device (which, and on which iOS version):
- [ ] Tried with both JIT and TCTI, if the change touches the emulator, JIT, or switching between
      the two
- [ ] Booted on a Mac with `make boot-guest`, if the change touches the guest image

### Commits

- [ ] Each commit is one change that builds on its own, and its message includes the why of it
- [ ] Subjects are short sentences in the imperative, such as "Add a benchmark suite for the
      emulator"
- [ ] `make format` has been run
- [ ] US spelling is used, in code, comments, UI text and messages
- [ ] `third-party/qemu` only moves to a commit on the fork's `tctish-edition`

### Anything Else

<!--
Things you want the reviewer to know such as any trade-offs you made, things you were unsure about,
things you would like looked at closely, and so on.
-->
