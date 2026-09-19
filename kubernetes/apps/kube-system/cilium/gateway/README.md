# Gateway Domain Configuration

## Current Configuration

| Gateway | Address | Listener hostnames | Certificate |
| --- | --- | --- | --- |
| `external-lab` | `192.168.168.211` | `*.${SECRET_DOMAIN}`, `*.${SECRET_DOMAIN_3}` | `wildcard-production-tls`, `wildcard-three-production-tls` |
| `external-prod` | `192.168.168.212` | `*.${SECRET_DOMAIN_2}` | `wildcard-two-production-tls` |
| `internal` | `192.168.168.208` | `*.k8s.${SECRET_DOMAIN}` | `k8s` |

The single `external` gateway was split into `external-lab` and `external-prod`
so each public domain gets its own address and Cloudflare tunnel. Routes must
name `external-lab` or `external-prod` — a `parentRef` to `external` silently
fails to attach and the hostname returns 404.

## DNS

Each gateway carries `external-dns.kubernetes.io/target`, so routes attached to
it are published as CNAMEs to that anchor (`vrtx.${SECRET_DOMAIN}` etc.) rather
than to the gateway's private address. The anchor A records themselves come
from the `external-dns.kubernetes.io/hostname` annotation under
`spec.infrastructure.annotations`, which Cilium copies onto the generated
`cilium-gateway-*` LoadBalancer service.

Use the `external-dns.kubernetes.io/` prefix — external-dns v0.22 dropped the
`external-dns.alpha.kubernetes.io/` default with no fallback. Annotations left
on the old prefix are ignored, which sends cloudflare-dns back to publishing
proxied A records at private addresses (Cloudflare error 9003) and makes
unifi-dns publish wildcards it should be skipping.

## Adding Additional Domains

1. **Update cluster secrets** to include:
   - `SECRET_DOMAIN` - Primary domain
   - `SECRET_DOMAIN_2` - Second domain
   - `SECRET_DOMAIN_3` - Third domain

2. **Ensure DNS is configured** for each domain:
   - Point `*.yourdomain.com` at the gateway serving it (see the table above)
   - Configure Cloudflare API access for Let's Encrypt DNS validation

3. **Certificates are generated automatically** via cert-manager:
   - `certificate.yaml` - `SECRET_DOMAIN`
   - `certificate-two.yaml` - `SECRET_DOMAIN_2`
   - `certificate-three.yaml` - `SECRET_DOMAIN_3`
   - `k8s-certificate.yaml` - `k8s.${SECRET_DOMAIN}` for the internal gateway

4. **Applications can use any domain** by setting the hostname in their HTTPRoute:

   ```yaml
   hostnames: ["app.${SECRET_DOMAIN_2}"]
   parentRefs:
     - name: external-prod
       namespace: kube-system
       sectionName: https
   ```

To add a fourth domain, create another certificate following the pattern and add
the listeners to the gateway that will serve it.
