# \WithdrawalsApi

All URIs are relative to *http://localhost*

Method | HTTP request | Description
------------- | ------------- | -------------
[**commit**](WithdrawalsApi.md#commit) | **POST** /api/v1/withdrawals/commit |
[**prepare**](WithdrawalsApi.md#prepare) | **POST** /api/v1/withdrawals/prepare |



## commit

> serde_json::Value commit(withdrawal_approval)


Consume a review once after checking wallet identity, expiry, exact inputs, recipient and costs. Browser clients use the durable submissions endpoint. After an uncertain response, check the saved submission; do not repeat with a new review.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**withdrawal_approval** | [**WithdrawalApproval**](WithdrawalApproval.md) |  | [required] |

### Return type

[**serde_json::Value**](serde_json::Value.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## prepare

> models::WithdrawalReview prepare(body)


### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**body** | **serde_json::Value** |  | [required] |

### Return type

[**models::WithdrawalReview**](WithdrawalReview.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)
