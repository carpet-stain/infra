# Cloudflare zones and DNS records as config-as-data (#9, epic #6), the
# same style repos.tf's local.repos uses: adding/changing a record is a
# single map edit reviewed as a diff. imports.tf (temporary) adopts what's
# already live in the account so `tofu apply` doesn't recreate a domain's
# mail/verification records out from under it — README's "Adding a repo"
# pattern, applied to DNS instead of GitHub repos.
#
# Record map keys are locally-descriptive, not Cloudflare ids, so adding or
# reordering a record never reshuffles another record's for_each address.

locals {
  zones = toset([
    "filmitinc.com",
    "leppez.com",
  ])

  dns_records = {
    "filmitinc.com" = {
      sendgrid-cname   = { type = "CNAME", name = "em5173.filmitinc.com", content = "u32746722.wl223.sendgrid.net", ttl = 1 }
      sendgrid-dkim-s1 = { type = "CNAME", name = "s1._domainkey.filmitinc.com", content = "s1.domainkey.u32746722.wl223.sendgrid.net", ttl = 1 }
      sendgrid-dkim-s2 = { type = "CNAME", name = "s2._domainkey.filmitinc.com", content = "s2.domainkey.u32746722.wl223.sendgrid.net", ttl = 1 }
      mx-route1        = { type = "MX", name = "filmitinc.com", content = "route1.mx.cloudflare.net", priority = 39, ttl = 1 }
      mx-route2        = { type = "MX", name = "filmitinc.com", content = "route2.mx.cloudflare.net", priority = 92, ttl = 1 }
      mx-route3        = { type = "MX", name = "filmitinc.com", content = "route3.mx.cloudflare.net", priority = 34, ttl = 1 }
      sendgrid-dkim-txt = {
        type    = "TXT"
        name    = "cf2024-1._domainkey.filmitinc.com"
        content = "\"v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiweykoi+o48IOGuP7GR3X0MOExCUDY/BCRHoWBnh3rChl7WhdyCxW3jgq1daEjPPqoi7sJvdg5hEQVsgVRQP4DcnQDVjGMbASQtrY4WmB1VebF+RPJB2ECPsEDTpeiI5ZyUAwJaVX7r6bznU67g7LvFq35yIo4sdlmtZGV+i0H4cpYH9+3JJ78k\" \"m4KXwaf9xUJCWF6nxeD+qG6Fyruw1Qlbds2r85U9dkNDVAS3gioCvELryh1TxKGiVTkg4wqHTyHfWsp7KD3WQHYJn0RyfJJu6YEmL77zonn7p2SRMvTMP3ZEXibnC9gz3nnhR6wcYL8Q7zXypKTMD58bTixDSJwIDAQAB\""
        ttl     = 1
      }
      spf = { type = "TXT", name = "filmitinc.com", content = "v=spf1 include:_spf.mx.cloudflare.net ~all", ttl = 1 }
    }

    "leppez.com" = {
      protonmail-dkim-1 = { type = "CNAME", name = "protonmail._domainkey.leppez.com", content = "protonmail.domainkey.d6ectspnpge3g4ppukfcmnwrdzps35wlxhsdqv3owvg6ka2qoyfyq.domains.proton.ch", ttl = 1 }
      protonmail-dkim-2 = { type = "CNAME", name = "protonmail2._domainkey.leppez.com", content = "protonmail2.domainkey.d6ectspnpge3g4ppukfcmnwrdzps35wlxhsdqv3owvg6ka2qoyfyq.domains.proton.ch", ttl = 1 }
      protonmail-dkim-3 = { type = "CNAME", name = "protonmail3._domainkey.leppez.com", content = "protonmail3.domainkey.d6ectspnpge3g4ppukfcmnwrdzps35wlxhsdqv3owvg6ka2qoyfyq.domains.proton.ch", ttl = 1 }
      icloud-dkim       = { type = "CNAME", name = "sig1._domainkey.leppez.com", content = "sig1.dkim.leppez.com.at.icloudmailadmin.com", ttl = 3600 }
      mx-icloud-1       = { type = "MX", name = "leppez.com", content = "mx01.mail.icloud.com", priority = 10, ttl = 3600 }
      mx-icloud-2       = { type = "MX", name = "leppez.com", content = "mx02.mail.icloud.com", priority = 10, ttl = 3600 }
      dmarc             = { type = "TXT", name = "_dmarc.leppez.com", content = "v=DMARC1; p=none; rua=mailto:brianleppez@protonmail.com", ttl = 1 }
      spf               = { type = "TXT", name = "leppez.com", content = "\"v=spf1 include:_spf.protonmail.ch mx include:icloud.com ~all\"", ttl = 3600 }
      apple-domain      = { type = "TXT", name = "leppez.com", content = "\"apple-domain=uuDhl8hQpTGfCHwr\"", ttl = 3600 }
      protonmail-verify = { type = "TXT", name = "leppez.com", content = "protonmail-verification=2d9cae1d3562ec6306aea15c0beaee475f722b55", ttl = 1 }
    }
  }

  # Flattened to a single map so cloudflare_dns_record can for_each over one
  # collection; "zone:key" keeps addresses unique across zones without
  # relying on any Cloudflare id.
  dns_records_flat = merge([
    for zone, records in local.dns_records : {
      for key, record in records : "${zone}:${key}" => merge(record, { zone = zone })
    }
  ]...)
}

resource "cloudflare_zone" "this" {
  for_each = local.zones

  name = each.key
  account = {
    id = var.cloudflare_account_id
  }
}

resource "cloudflare_dns_record" "this" {
  for_each = local.dns_records_flat

  zone_id  = cloudflare_zone.this[each.value.zone].id
  type     = each.value.type
  name     = each.value.name
  content  = each.value.content
  ttl      = each.value.ttl
  priority = try(each.value.priority, null)
}
