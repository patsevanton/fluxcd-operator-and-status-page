# Создание внешнего IP-адреса в Yandex Cloud
resource "yandex_vpc_address" "addr" {
  name = "fluxcd-pip"  # Имя ресурса внешнего IP-адреса

  external_ipv4_address {
    zone_id = yandex_vpc_subnet.fluxcd-a.zone  # Зона доступности, где будет выделен IP-адрес
  }
}

# Создание публичной DNS-зоны в Yandex Cloud DNS
resource "yandex_dns_zone" "apatsev-org-ru" {
  name  = "apatsev-org-ru-zone"  # Имя ресурса DNS-зоны

  zone  = "apatsev.org.ru."      # Доменное имя зоны (с точкой в конце)
  public = true                  # Указание, что зона является публичной

  # Привязка зоны к VPC-сети, чтобы можно было использовать приватный DNS внутри сети
  private_networks = [yandex_vpc_network.fluxcd.id]
}

# Создание DNS-записи типа A, указывающей на внешний IP
resource "yandex_dns_recordset" "grafana" {
  zone_id = yandex_dns_zone.apatsev-org-ru.id
  name    = "grafana.apatsev.org.ru."
  type    = "A"
  ttl     = 200
  data    = [yandex_vpc_address.addr.external_ipv4_address[0].address]
}

resource "yandex_dns_recordset" "victorialogs" {
  zone_id = yandex_dns_zone.apatsev-org-ru.id
  name    = "victorialogs.apatsev.org.ru."
  type    = "A"
  ttl     = 200
  data    = [yandex_vpc_address.addr.external_ipv4_address[0].address]
}

resource "yandex_dns_recordset" "victoriametrics" {
  zone_id = yandex_dns_zone.apatsev-org-ru.id
  name    = "vmselect.apatsev.org.ru."
  type    = "A"
  ttl     = 200
  data    = [yandex_vpc_address.addr.external_ipv4_address[0].address]
}

# Flux Operator Web UI (Mission Control / Status Page)
resource "yandex_dns_recordset" "flux_web" {
  zone_id = yandex_dns_zone.apatsev-org-ru.id
  name    = "flux.apatsev.org.ru."
  type    = "A"
  ttl     = 200
  data    = [yandex_vpc_address.addr.external_ipv4_address[0].address]
}
