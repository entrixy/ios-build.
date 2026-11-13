# iOS adaptation references

Entrixy Android is the source for screen meaning, actions and owned artwork.
iOS references guide native presentation, not new product scenarios.

- Apple Home: https://support.apple.com/guide/iphone/control-accessories-iph0a717a8fd/18.0/ios/18.0
  Object controls stay in the main list. Do not invent a separate read-only object page.
- Apple Wallet, Add to Wallet (official iOS 18 screenshot):
  https://cdsassets.apple.com/live/7WUAS350/images/apple-pay/locale/uk-ua/ios-18-iphone-16-pro-wallet-add-transit-card.png
  Import methods use full-width neutral rows with clear labels, not pale blue chips.
- Apple Phone history: https://support.apple.com/en-lamr/guide/iphone/iph21d1e1f56/ios
  Clear time/actor/object hierarchy. The actual data schema is Entrixy Android's
  JournalEntry (ts, who, what, actionKey, result, level).
- Apple button guidance: https://developer.apple.com/design/human-interface-guidelines/buttons
  Use a clear primary action and distinct secondary actions. Disabled actions remain
  recognizably disabled and readable; avoid tint-on-tint labels.

Use the existing Entrixy navy (#1B1D3B) for primary text/actions, adaptive monochrome
surfaces, readable secondary text and semantic red only for destructive actions/errors.
Keep existing Entrixy logo and Android object preset artwork. Connection state belongs
in key status, not the user's action history. With no real actions, the journal is empty.

No reference screenshots are bundled in the app. No fabricated action rows are used
for public previews. The incomplete actuation port is not represented by fake controls.

The main four tabs share one leading circular Entrixy mark, without the wordmark. Preserve the exact five polygons from logo-animated-icon.svg. The three LED faces change independently between #E27474, #95C11F and the adaptive base ink: 0.25-second transitions, initial delay up to 400 ms, then 80 + random^2.2 × 1600 ms. Pause animation outside the foreground and respect Reduce Motion. Do not put the horizontal wordmark in a toolbar capsule.
