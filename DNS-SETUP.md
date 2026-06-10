# DNS setup — delegating a subdomain to your VPS

For dnstt to work, recursive resolvers on the internet must forward queries for
your **tunnel domain** (e.g. `t.example.com`) to **your VPS**. You do this with
an `NS` delegation plus a glue/`A` record.

You said your domain already has `MX`, `NS`, `SOA` records visible — good, that
means you control its zone and can add the records below.

---

## 1. Pick names

| Name                | Meaning                                            |
|---------------------|----------------------------------------------------|
| `example.com`       | your registered domain                             |
| `t.example.com`     | the **tunnel domain** (what the app & server use)  |
| `tns.example.com`   | the **name server** hostname pointing at your VPS  |
| `203.0.113.10`      | your **VPS public IP** (replace with yours)        |

---

## 2. Records to add at your DNS provider

Add these to the `example.com` zone:

```dns
; Glue / A record: tns.example.com -> your VPS IP
tns.example.com.   IN  A   203.0.113.10

; Delegate the tunnel subdomain to your VPS name server
t.example.com.     IN  NS  tns.example.com.
```

That is the minimum. After this, any query for `<stuff>.t.example.com` is sent
by recursive resolvers to `203.0.113.10:53`, where `dnstt-server` is listening.

> Set a **low TTL** (e.g. 300s) while testing so changes propagate quickly.

---

## 3. Registrar glue record (only if your NS is under the same domain)

Because `tns.example.com` is *inside* the domain it serves, some registrars
require you to register it as a **host / glue record** in the registrar control
panel (often called "Register a nameserver" / "Glue records"), mapping
`tns.example.com` → `203.0.113.10`.

If you instead use a name like `ns.some-other-domain.com`, glue is not needed.

---

## 4. Verify

From your laptop (not on the VPS):

```bash
# NS delegation present?
dig +short NS t.example.com
# expect: tns.example.com.

# Glue resolves to your VPS?
dig +short A tns.example.com
# expect: 203.0.113.10

# Does a query reach your dnstt-server? (TXT will look like garbage = good)
dig +short TXT test.t.example.com @1.1.1.1
```

If the last query reaches your VPS, check the server logs:

```bash
journalctl -u dnstt-server -f
```

---

## 5. Resolver choice in the app

The app's **Resolver** field is the recursive resolver the client sends DNS
queries *to*. Options:

| Mode | Value example                       | Notes                                  |
|------|-------------------------------------|----------------------------------------|
| DoH  | `https://1.1.1.1/dns-query`         | Best on restrictive networks (HTTPS)   |
| DoT  | `1.1.1.1:853`                       | Encrypted, port 853                    |
| UDP  | `1.1.1.1:53`                        | Simplest; use the network's own resolver for captive-portal bypass |

On a captive portal, try the **network-provided resolver** (the DNS server your
DHCP lease hands you) over UDP — that is usually the one allowed before login.
