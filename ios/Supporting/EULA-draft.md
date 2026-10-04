# Custom licence agreement — DRAFT, needs legal review

**Why this file exists.** If you ship on the App Store without supplying your own licence
agreement, Apple applies its standard Licensed Application End User License Agreement. That
default limits use to devices the user "owns or controls" and caps the number of devices per
Apple Account. GPLv3 §10 forbids imposing "any further restrictions on the exercise of the rights
granted or affirmed under this License." Those two cannot both be satisfied, and this conflict is
what got VLC removed from the App Store in 2011 after a GPL copyright holder filed a takedown.

**What to do.** Paste an agreed version of the text below into App Store Connect under *App
Information → License Agreement*, replacing Apple's default. This is free and takes a minute.

**This is a draft.** It is a starting point written by an engineer, not advice from a lawyer. Have
a lawyer review it before you publish, particularly the interaction between GPLv3 and Apple's
minimum required terms.

---

## Licence Agreement for Chess Analyser

Chess Analyser is free software. It is licensed to you under the **GNU General Public License,
version 3 or later** ("GPLv3"), a copy of which is included in the application and available at
<https://www.gnu.org/licenses/gpl-3.0.html>.

Your rights to use, copy, modify and redistribute this application are those granted by GPLv3 and
are not limited by this agreement. In particular, and notwithstanding any other terms presented
to you in connection with the distribution of this application:

1. You may use this application on any number of devices.
2. You may obtain the complete corresponding source code for this application, and you may modify
   it and redistribute your modified version under the same licence.
3. No term of this agreement, and no term of any agreement applied by the distribution platform,
   operates to restrict the rights GPLv3 grants you. To the extent any such term conflicts with
   GPLv3, GPLv3 prevails and the conflicting term does not apply to this application.

### Source code

The complete corresponding source for this build is published at
`<REPLACE WITH YOUR REAL SOURCE URL>`. If you cannot obtain it there, contact
`<REPLACE WITH YOUR CONTACT ADDRESS>` and it will be provided.

This application includes Stockfish (<https://stockfishchess.org>), copyright © 2004–2026 The
Stockfish developers, also licensed under GPLv3. Stockfish's sources are included, unmodified, in
the published corresponding source.

The chess pieces are the cburnett set by Colin M.L. Burnett, licensed under the GNU General Public
License version 2 or later and used here under version 3. They are included, unmodified, in the
published corresponding source.

### No warranty

As stated in GPLv3 sections 15 and 16, this application is provided without any warranty, to the
extent permitted by applicable law. You bear the entire risk as to its quality and performance.

### Apple's required terms

Apple Inc. is not a party to this agreement. Apple has no obligation to furnish any maintenance
or support for this application, and no warranty obligation of any kind with respect to it. Apple
is not responsible for addressing any claim relating to this application, including product
liability claims, any claim that the application fails to conform to a legal or regulatory
requirement, or any claim arising under consumer protection or similar legislation. Apple and its
subsidiaries are third-party beneficiaries of this agreement and may enforce its terms against
you as they relate to your use of the application.

### Not affiliated with Chess.com

This application reads publicly available game data from Chess.com's Published-Data API. It is an
independent work and is not affiliated with, endorsed by, or sponsored by Chess.com.

### Subscription

An optional subscription unlocks analysis beyond the free window. It is billed by Apple and
managed in your Apple Account settings. Because this application is free software, nothing in
GPLv3 prevents anyone from building and distributing a version without that check; the
subscription supports development rather than restricting the software.
