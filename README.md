# Контрольная работа №2  
## Требования
Перед началом убедитесь, что установлены:

- **Terraform ≥ 1.3**
- **Yandex Cloud CLI**
- Выполнена авторизация:
  ```
  yc init
  ```
## Развертывание инфраструктуры
1) Инициализация Terraform
```
terraform init
```
2) Проверка плана
```
terraform plan \
  -var="cloud_id=" \
  -var="folder_id="
```
3) Применение конфигурации
```
terraform apply \
  -var="cloud_id=" \
  -var="folder_id="
```

После выполнения Terraform будет выведен API Gateway URL.

## Загрузка документов
Загрузка README TypeScript из публичного репозитория
```
curl -X POST https://$API_URL/upload \
  -H "Content-Type: application/json" \
  -d '{
    "name": "typescript.txt",
    "url": "https://raw.githubusercontent.com/microsoft/TypeScript/main/README.md"
  }' -i
```
## Получение документов
```
curl https://$API_URL/documents
```
### Получить документ по ID
```
curl https://$API_URL/documents/{id}
```

### Удаление инфраструктуры
```
terraform destroy \
  -var="cloud_id=" \
  -var="folder_id="
```
