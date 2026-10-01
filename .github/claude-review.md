Workflows in this repo run in every MnemoShare repository's CI. Treat changes
to permissions, secrets, token minting, the posting logic and the exact-head
merge-gate check as security-sensitive: a mistake here weakens the review gate
everywhere at once.
