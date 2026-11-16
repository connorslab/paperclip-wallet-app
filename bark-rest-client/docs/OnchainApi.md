# \OnchainApi

All URIs are relative to *http://localhost*

Method | HTTP request | Description
------------- | ------------- | -------------
[**onchain_address**](OnchainApi.md#onchain_address) | **POST** /api/v1/onchain/addresses/next | Generate on-chain address
[**onchain_balance**](OnchainApi.md#onchain_balance) | **GET** /api/v1/onchain/balance | Get on-chain balance
[**onchain_drain**](OnchainApi.md#onchain_drain) | **POST** /api/v1/onchain/drain | Drain on-chain wallet
[**onchain_message_sign**](OnchainApi.md#onchain_message_sign) | **POST** /api/v1/onchain/message/sign | Sign an on-chain Taproot address ownership message using BIP322-simple
[**onchain_message_verify**](OnchainApi.md#onchain_message_verify) | **POST** /api/v1/onchain/message/verify | Verify a BIP322-simple Taproot address ownership message
[**onchain_send**](OnchainApi.md#onchain_send) | **POST** /api/v1/onchain/send | Send on-chain payment
[**onchain_send_many**](OnchainApi.md#onchain_send_many) | **POST** /api/v1/onchain/send-many | Send to multiple addresses
[**onchain_sync**](OnchainApi.md#onchain_sync) | **POST** /api/v1/onchain/sync | Sync on-chain wallet
[**onchain_transactions**](OnchainApi.md#onchain_transactions) | **GET** /api/v1/onchain/transactions | List on-chain transactions
[**onchain_utxos**](OnchainApi.md#onchain_utxos) | **GET** /api/v1/onchain/utxos | List on-chain UTXOs
[**replacement_commit**](OnchainApi.md#replacement_commit) | **POST** /api/v1/onchain/replacement/commit |
[**replacement_prepare**](OnchainApi.md#replacement_prepare) | **POST** /api/v1/onchain/replacement/prepare |
[**send_commit**](OnchainApi.md#send_commit) | **POST** /api/v1/onchain/send/commit |
[**send_prepare**](OnchainApi.md#send_prepare) | **POST** /api/v1/onchain/send/prepare |



## onchain_address

> models::Address onchain_address()
Generate on-chain address

Generates a new on-chain receiving address. Each call returns the next unused address from the wallet's HD keychain.

### Parameters

This endpoint does not need any parameter.

### Return type

[**models::Address**](Address.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## onchain_balance

> models::OnchainBalance onchain_balance()
Get on-chain balance

Returns the current on-chain wallet balance, broken down by confirmation status. The `trusted_spendable_sat` field is the sum of `confirmed_sat` and `trusted_pending_sat`—the balance that can be safely spent without risk of double-spend.

### Parameters

This endpoint does not need any parameter.

### Return type

[**models::OnchainBalance**](OnchainBalance.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## onchain_drain

> models::Send onchain_drain(onchain_drain_request)
Drain on-chain wallet

Sends the entire on-chain wallet balance to the specified address. The recipient receives the full balance minus transaction fees. Broadcasts immediately at a fee rate targeting confirmation within three blocks and returns the transaction ID.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**onchain_drain_request** | [**OnchainDrainRequest**](OnchainDrainRequest.md) |  | [required] |

### Return type

[**models::Send**](Send.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## onchain_message_sign

> models::OnchainMessageProof onchain_message_sign(onchain_message_request)
Sign an on-chain Taproot address ownership message using BIP322-simple

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**onchain_message_request** | [**OnchainMessageRequest**](OnchainMessageRequest.md) |  | [required] |

### Return type

[**models::OnchainMessageProof**](OnchainMessageProof.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## onchain_message_verify

> models::OnchainMessageVerification onchain_message_verify(onchain_message_verify_request)
Verify a BIP322-simple Taproot address ownership message

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**onchain_message_verify_request** | [**OnchainMessageVerifyRequest**](OnchainMessageVerifyRequest.md) |  | [required] |

### Return type

[**models::OnchainMessageVerification**](OnchainMessageVerification.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## onchain_send

> models::Send onchain_send(onchain_send_request)
Send on-chain payment

Sends the specified amount to an on-chain address. Broadcasts the transaction immediately at a fee rate targeting confirmation within three blocks and returns the transaction ID.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**onchain_send_request** | [**OnchainSendRequest**](OnchainSendRequest.md) |  | [required] |

### Return type

[**models::Send**](Send.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## onchain_send_many

> models::Send onchain_send_many(onchain_send_many_request)
Send to multiple addresses

Batches multiple payments into a single on-chain transaction. Each destination is formatted as `address:amount`. Broadcasts the transaction immediately at a fee rate targeting confirmation within three blocks and returns the transaction ID.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**onchain_send_many_request** | [**OnchainSendManyRequest**](OnchainSendManyRequest.md) |  | [required] |

### Return type

[**models::Send**](Send.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## onchain_sync

> onchain_sync()
Sync on-chain wallet

Syncs the on-chain wallet state with the chain source. Fetches new blocks and transactions, updates the UTXO set, and re-submits any stale unconfirmed transactions to the mempool.

### Parameters

This endpoint does not need any parameter.

### Return type

 (empty response body)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## onchain_transactions

> Vec<models::WalletTxInfo> onchain_transactions()
List on-chain transactions

Returns all on-chain wallet transactions, ordered from oldest to newest. Each entry includes the raw transaction, its fee (when known), the wallet's net balance change, and confirmation status. The fee is `null` for inbound or collaboratively-funded transactions whose foreign prevouts BDK has not indexed.

### Parameters

This endpoint does not need any parameter.

### Return type

[**Vec<models::WalletTxInfo>**](WalletTxInfo.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## onchain_utxos

> Vec<models::UtxoInfo> onchain_utxos()
List on-chain UTXOs

Returns all UTXOs in the on-chain wallet. Each entry includes the outpoint, amount, and confirmation height (if confirmed).

### Parameters

This endpoint does not need any parameter.

### Return type

[**Vec<models::UtxoInfo>**](UtxoInfo.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## replacement_commit

> serde_json::Value replacement_commit(replacement_approval)


Consume a 60-second fee review once after refreshing and verifying the original signatures. Returns txid and submitted or pending_broadcast. Check transaction status before any further action.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**replacement_approval** | [**ReplacementApproval**](ReplacementApproval.md) |  | [required] |

### Return type

[**serde_json::Value**](serde_json::Value.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## replacement_prepare

> serde_json::Value replacement_prepare(replacement_request)


Review a replacement of a locally authorized ordinary outgoing payment. Zero new_fee_sat requests twice the original fee. Preserves all recipients, amounts and inputs; additional fee comes only from original change. Returns original_txid, replacement_txid, old_fee_sat, new_fee_sat, additional_fee_sat and recipients.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**replacement_request** | [**ReplacementRequest**](ReplacementRequest.md) |  | [required] |

### Return type

[**serde_json::Value**](serde_json::Value.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## send_commit

> serde_json::Value send_commit(send_approval)


Consume the prepared review once. Requires the same wallet, request ID, total cost and unspent inputs. Returns txid and submitted or pending_broadcast; neither means confirmed. Never retry an uncertain commit automatically.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**send_approval** | [**SendApproval**](SendApproval.md) |  | [required] |

### Return type

[**serde_json::Value**](serde_json::Value.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## send_prepare

> serde_json::Value send_prepare(onchain_send_request)


Prepare an exact 60-second on-chain review; returns request_id, destination, amount_sat, fee_sat and total_sat. Does not sign or broadcast.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**onchain_send_request** | [**OnchainSendRequest**](OnchainSendRequest.md) |  | [required] |

### Return type

[**serde_json::Value**](serde_json::Value.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)
