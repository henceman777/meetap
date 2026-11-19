# MeeTap 最小 IAM 权限

> 从 README 挪过来的。给 MeeTap 使用的 IAM 用户或角色附加下面的策略（按需启用 SES 部分）。用管理员凭证也能跑，这一页是给想收紧权限的人看的。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ObjectOps",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:PutBucketPublicAccessBlock"
      ],
      "Resource": [
        "arn:aws:s3:::meetap-transcribe-*",
        "arn:aws:s3:::meetap-transcribe-*/*"
      ]
    },
    {
      "Sid": "TranscribeStartJob",
      "Effect": "Allow",
      "Action": ["transcribe:StartTranscriptionJob"],
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:RequestedRegion": "us-east-1" }
      }
    },
    {
      "Sid": "TranscribeGetDeleteJob",
      "Effect": "Allow",
      "Action": [
        "transcribe:GetTranscriptionJob",
        "transcribe:DeleteTranscriptionJob"
      ],
      "Resource": "arn:aws:transcribe:us-east-1:*:transcription-job/meetap-*"
    },
    {
      "Sid": "BedrockGlobalInferenceProfile",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModelWithResponseStream"],
      "Resource": [
        "arn:aws:bedrock:us-east-1:<ACCOUNT>:inference-profile/global.anthropic.claude-sonnet-5"
      ],
      "Condition": {
        "StringEquals": { "aws:RequestedRegion": "us-east-1" }
      }
    },
    {
      "Sid": "BedrockInRegionModel",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModelWithResponseStream"],
      "Resource": [
        "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-5"
      ],
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "us-east-1",
          "bedrock:InferenceProfileArn": "arn:aws:bedrock:us-east-1:<ACCOUNT>:inference-profile/global.anthropic.claude-sonnet-5"
        }
      }
    },
    {
      "Sid": "BedrockGlobalModel",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModelWithResponseStream"],
      "Resource": [
        "arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-5"
      ],
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "unspecified",
          "bedrock:InferenceProfileArn": "arn:aws:bedrock:us-east-1:<ACCOUNT>:inference-profile/global.anthropic.claude-sonnet-5"
        }
      }
    },
    {
      "Sid": "SESSendFromConfiguredSender",
      "Effect": "Allow",
      "Action": ["ses:SendRawEmail"],
      "Resource": "arn:aws:ses:us-east-1:*:identity/noreply@example.com",
      "Condition": {
        "StringEquals": {
          "ses:FromAddress": "noreply@example.com"
        }
      }
    }
  ]
}
```

**最小权限说明**（按实际调用收紧，切 region / 换模型时记得同步 ARN）：

- **S3**：meetap 首次运行会自动建桶（`meetap-transcribe-<AccountID 短哈希>-<region>`），不用手动预建。这份策略没有建桶权限，所以**套用时首次运行请临时补上 `s3:CreateBucket`**（跑一次后可收回），或手动预建同名桶。策略里也没有 `s3:ListBucket`：meetap 查桶在不在时查不到、建桶时报权限不够，都不算失败，照常上传。
- **Transcribe**：`StartTranscriptionJob` 不支持资源级 ARN，只能 `Resource:"*"` + `aws:RequestedRegion` 锁 region；`Get/Delete` 已收窄到 `transcription-job/meetap-*`。
- **Bedrock**：默认模型 `global.anthropic.claude-sonnet-5` 是 global 跨区域推理配置文件，请求可能被路由到任意支持的商业区域，所以照 [AWS 文档](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html)要三段权限，缺一段都会被拒：
  1. 本区域的推理配置文件 `arn:aws:bedrock:<区域>:<ACCOUNT>:inference-profile/global.anthropic.claude-sonnet-5`；
  2. 本区域的基础模型 `arn:aws:bedrock:<区域>::foundation-model/anthropic.claude-sonnet-5`，带 `bedrock:InferenceProfileArn` 条件；
  3. 不分区域的基础模型 `arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-5`（区域和账号故意留空），带 `bedrock:InferenceProfileArn` 条件，`aws:RequestedRegion` 是 `unspecified`。

  把 `<ACCOUNT>` 换成你的账号 ID，`us-east-1` 换成配置里的 `region`。生成纪要和认日历都走流式接口（ConverseStream），所以动作只要 `bedrock:InvokeModelWithResponseStream`。换成区域内的模型（比如 `us.` 开头的推理配置文件，或者 Nova / Llama / DeepSeek 等）时，ARN 要照那个模型改。组织里用 SCP 按区域拦截的，要放行 `aws:RequestedRegion` 为 `unspecified` 的请求，见上面那页文档。
- **SES**：把两处 `noreply@example.com` 换成你**已在 SES 验证**的发件地址，且 ARN 的 region 要与验证 region 一致（SES 按 region 独立验证）；验证整个域时改用域 identity ARN（`identity/example.com`）。**新账户默认 sandbox**，只能发给已验证地址，群发需先申请生产访问。
