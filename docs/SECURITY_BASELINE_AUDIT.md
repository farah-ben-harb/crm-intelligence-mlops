# Audit des résultats Checkov Terraform

**Date de l'audit :** 16 novembre 2026
**Configuration de référence :** commit `d7de067` sur `feat/aws-terraform`
**Périmètre :** `infra/aws`; aucun correctif de ressource AWS appliqué.

## Comparaison

Le scan de référence a rapporté 90 contrôles réussis et 10 échecs. Le scan après la proposition de dashboard rapporte 89 réussis et 11 échecs. Aucun échec n'est associé à `aws_cloudwatch_dashboard.observability` ni à une nouvelle ressource du dashboard.

Les 10 contrôles présents dans la référence restent inchangés :

| Contrôle | Ressource | Constat Checkov | Risque à examiner séparément |
|---|---|---|---|
| `CKV_AWS_158` | `aws_cloudwatch_log_group.api` | Log Group sans clé KMS dédiée | Chiffrement au repos avec la clé de service; évaluer besoin et coût d'une clé KMS. |
| `CKV_AWS_338` | `aws_cloudwatch_log_group.api` | Rétention de 7 jours au lieu d'un an | Historique limité; la rétention de 7 jours est conservée pour maîtriser le stockage. |
| `CKV_AWS_126` | `aws_instance.crm` | Monitoring EC2 détaillé désactivé | Métriques EC2 moins fréquentes; monitoring détaillé peut ajouter un coût. |
| `CKV_AWS_88` | `aws_instance.crm` | Instance avec adresse IP publique | Surface d'exposition réseau; le SG et le modèle SSM actuel demandent un examen d'architecture dédié. |
| `CKV_AWS_136` | `aws_ecr_repository.api` | ECR utilise AES256, pas une clé KMS dédiée | Contrôle de gestion de clés dédié non disponible; évaluer coût et exigences de conformité. |
| `CKV2_AWS_62` | `aws_s3_bucket.models` | Notifications d'événements S3 absentes | Pas de notification automatisée des événements du bucket. |
| `CKV2_AWS_61` | `aws_s3_bucket.models` | Lifecycle S3 absente | Les versions/objets n'ont pas de règle de transition ou d'expiration configurée. |
| `CKV_AWS_18` | `aws_s3_bucket.models` | Access logging S3 absent | Pas de journal dédié des accès au bucket. |
| `CKV_AWS_144` | `aws_s3_bucket.models` | Réplication inter-région absente | Pas de copie de reprise dans une autre région; réplication aurait un coût. |
| `CKV_AWS_145` | `aws_s3_bucket.models` | KMS S3 absent | Le bucket utilise le chiffrement géré par S3 configuré; pas de clé KMS dédiée. |

## Écart observé après la référence

`CKV_AWS_135` apparaît parce que `compute.tf` a été aligné sur l'état AWS observé : `EbsOptimized=false`. Le plan précédent montrait que passer la valeur à `true` remplace EC2. La configuration reste donc alignée sur l'instance pour empêcher ce remplacement. Ce constat n'est pas lié au dashboard et n'est pas masqué dans Checkov.

## Résultat dashboard

La définition du dashboard ne crée aucune métrique, alarme, politique IAM ou ressource AWS. Les requêtes des widgets lisent le Log Group existant. Le scan complet conserve les 10 échecs de référence et le constat `CKV_AWS_135` lié à la valeur EC2. Aucun de ces contrôles n'a été désactivé globalement ou localement.

Les risques de ce rapport sont documentés pour priorisation. Leur correction demanderait des décisions séparées sur coûts, exposition réseau et politiques de conservation; aucune n'est incluse ici.
