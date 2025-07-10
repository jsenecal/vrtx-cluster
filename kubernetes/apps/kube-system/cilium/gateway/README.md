# Gateway Domain Configuration

## Adding Additional Domains

This gateway configuration supports multiple domains using secrets. To add your domains:

1. **Update cluster secrets** to include:
   - `SECRET_DOMAIN` - Primary domain (already configured)
   - `SECRET_DOMAIN_2` - Second domain
   - `SECRET_DOMAIN_3` - Third domain

2. **Ensure DNS is configured** for each domain:
   - Point `*.yourdomain.com` to the external gateway IP: `192.168.168.210`
   - Configure Cloudflare API access for Let's Encrypt DNS validation

3. **Certificates will be automatically generated** via cert-manager using:
   - `certificate.yaml` - For PRIMARY domain (SECRET_DOMAIN)
   - `certificate-two.yaml` - For SECOND domain (SECRET_DOMAIN_2)
   - `certificate-three.yaml` - For THIRD domain (SECRET_DOMAIN_3)

4. **Applications can use any domain** by setting the hostname in their HTTPRoute:
   ```yaml
   hostnames: ["app.${SECRET_DOMAIN_2}"]
   ```

## Current Configuration

- **External Gateway**: Supports wildcard routing for all three domains
- **Internal Gateway**: Only configured for `*.k8s.${SECRET_DOMAIN}`
- **Certificates**: Wildcard certificates for each domain via Let's Encrypt

## Adding More Domains

To add more than 3 domains, create additional certificate files following the pattern and update the gateway listeners accordingly.