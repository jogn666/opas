# OPAS SmartGuide + Simulated OPAS — Connected Test Package

This package contains two separate local applications connected through the SmartGuide server-side API proxy. It is intended for local prototype testing only.

## 1. What is connected

- Simulated OPAS applicant application (registration, login, passport application, document steps and simulated payment) runs on `http://localhost:3000`.
- OPAS SmartGuide with Resend notification code runs on `http://localhost:3001`.
- SmartGuide reads the simulated payment ledger, application status and paid-but-not-submitted detections from Simulated OPAS through these endpoints:
  - `GET http://127.0.0.1:3000/api/payment/transactions`
  - `GET http://127.0.0.1:3000/api/applications/status`
  - `GET http://127.0.0.1:3000/api/smartguide/detections`
- Simulated OPAS sends payment events to its own `/api/payment/process` endpoint and publishes application changes to `/api/applications/sync`.
- SmartGuide's backend owns applicant guidance, validation, and the 30-second reminder scheduler. Signed HMAC-protected requests connect OPAS to those engines; eligible SmartGuide Message Board reminders appear in the OPAS applicant dashboard, with read/action updates synchronized back to SmartGuide.

## 2. Requirements and portable setup

Use Windows with Node.js 20.19+ or 22.12+ (including npm). Extract or copy the
complete folder to a normal local path. On a new computer, open the folder and run:

```powershell
.\start-demo.cmd -InstallDependencies
```

This restores both projects from their lockfiles, creates per-computer `.env.local`
files from the safe templates, generates matching local OPAS integration secrets,
and opens both development servers in separate windows. The apps run at
`http://localhost:3000` (Simulated OPAS) and `http://localhost:3001` (SmartGuide).
Keep both windows open. The launcher reuses either app if it is already responding
and never kills an unrelated process occupying a port.

To also install the local offline assistant on a computer that already has Ollama
installed and running, run:

```powershell
.\start-demo.cmd -InstallDependencies -InstallOllamaModel
```

This downloads the `llama3.2:1b` base model (about 1.3 GB in the current setup) and
builds `ravok:latest` from the repository `Modelfile`. The model is stored in
Ollama's local model cache, not inside this folder. Without this model, offline assistant
responses are unavailable.

## 3. Per-computer configuration

API credentials are intentionally not included in the templates or setup script.
On each computer, add valid `GROQ_API_KEY` and `GEMINI_API_KEY` values to
`OPAS-SmartGuide/.env.local` to use Groq first and Gemini as fallback. Never put
real keys in `.env.example`, commit them, or send them in chat. Without cloud keys,
SmartGuide can use the local Ollama model when it is installed and running.

The launcher creates or synchronizes `OPAS_INTEGRATION_SECRET` locally for the two
apps and sets their localhost API URLs. Keep `.env.local` files private. Do not copy
live applicant data, production credentials, or real payment information into this
prototype.

## 4. Test the connection

## 5. Test the connection

1. Open `http://localhost:3000`.
2. Register a fictional test applicant. Do not use real NRC details, official OPAS credentials or real applicant information.
3. Create a passport application and complete the personal details and document steps.
4. Make a simulated successful payment. This is a prototype transaction only; it does not contact a bank or the Government Payment Gateway.
5. Leave the application in the paid-but-not-submitted state if the application flow permits it.
6. Open `http://localhost:3001` in another browser tab.
7. Open SmartGuide's staff-only engine console and sign in using a staff demo account. The local demo password configured in `.env.local.example` is `GuidewiseDemo2026!`. Applicants continue to use Simulated OPAS and should not sign in to SmartGuide.
8. Open the Payment / Submission Monitor and refresh it. It should request the transaction and detection data from Simulated OPAS through the SmartGuide backend proxy.
9. Submit the application in Simulated OPAS and refresh the SmartGuide monitor. The paid-but-not-submitted detection should clear once the Simulated OPAS status endpoint reports the submitted state.

## 6. Connection check (optional)

With both apps running, open these URLs in a browser to check the Simulated OPAS API directly:

- `http://127.0.0.1:3000/api/payment/transactions`
- `http://127.0.0.1:3000/api/applications/status`
- `http://127.0.0.1:3000/api/smartguide/detections`

The SmartGuide proxy routes are protected by SmartGuide sign-in. The UI monitor is the recommended test path.

## 7. Important limitations

- This is a simulated local integration, not a connection to Zambia's official OPAS, a real payment gateway, a bank, or a Ministry database.
- Application status and synthetic identity records are still development/demo stores. Payment ledger transactions are additionally saved to `Simulated-OPAS/data/payment-ledger.json` for local restart persistence. This is a local prototype file, not a production database; protect and clear it when appropriate.
- SmartGuide web access is restricted to prototype staff accounts; applicants use Simulated OPAS and cannot sign in to SmartGuide. A real staff identity provider and approved OPAS service-to-service integration are still required before production.
- Resend delivery requires valid server-side `RESEND_API_KEY` and `NOTIFICATION_FROM_EMAIL` configuration. Use `NOTIFICATION_TEST_RECIPIENT` to redirect test emails to your own inbox. A successful API request is not the same as confirmed delivery.
- Do not use real passport applicant data, official passwords, production payment details, or live government credentials in this demo.
- Production deployment requires Ministry approval, documented and authenticated APIs, TLS, secure identity integration, durable database storage, access controls, audit logging, monitoring, and security review.

## 8. Preserving your original project

The SmartGuide folder in this package is copied from the Resend standalone test project; the Simulated OPAS folder is included alongside it as a separate application. Your uploaded original archive is not overwritten by this package.
