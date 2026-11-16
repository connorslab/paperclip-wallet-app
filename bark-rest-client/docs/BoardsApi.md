# \BoardsApi

All URIs are relative to *http://localhost*

Method | HTTP request | Description
------------- | ------------- | -------------
[**board_all**](BoardsApi.md#board_all) | **POST** /api/v1/boards/board-all | Board all on-chain bitcoin
[**board_amount**](BoardsApi.md#board_amount) | **POST** /api/v1/boards/board-amount | Board a specific amount
[**commit_review**](BoardsApi.md#commit_review) | **POST** /api/v1/boards/commit |
[**get_pending_boards**](BoardsApi.md#get_pending_boards) | **GET** /api/v1/boards/pending | List pending boards
[**prepare_review**](BoardsApi.md#prepare_review) | **POST** /api/v1/boards/prepare |



## board_all

> models::PendingBoardInfo board_all()
Board all on-chain bitcoin

Moves all bitcoin in the on-chain wallet onto the Ark protocol. Creates and broadcasts a funding transaction that drains the on-chain balance into a single VTXO, then returns the pending board details. The resulting VTXO is not spendable off-chain until the funding transaction reaches the number of on-chain confirmations required by the Ark server.

### Parameters

This endpoint does not need any parameter.

### Return type

[**models::PendingBoardInfo**](PendingBoardInfo.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## board_amount

> models::PendingBoardInfo board_amount(board_request)
Board a specific amount

Moves the specified amount of bitcoin in the on-chain wallet onto the Ark protocol. Creates and broadcasts a funding transaction, then returns the pending board details. The resulting VTXO is not spendable off-chain until the funding transaction reaches the number of on-chain confirmations required by the Ark server.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**board_request** | [**BoardRequest**](BoardRequest.md) |  | [required] |

### Return type

[**models::PendingBoardInfo**](PendingBoardInfo.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## commit_review

> serde_json::Value commit_review(board_approval)


Consume the exact reviewed funding transaction once after checking wallet identity, expiry, recovery costs and unspent inputs. Pending does not mean spendable. Check status after an uncertain response; never automatically submit a new board.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**board_approval** | [**BoardApproval**](BoardApproval.md) |  | [required] |

### Return type

[**serde_json::Value**](serde_json::Value.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## get_pending_boards

> Vec<models::PendingBoardInfo> get_pending_boards()
List pending boards

Returns all boards whose funding transactions have not yet reached the number of on-chain confirmations required by the Ark server.

### Parameters

This endpoint does not need any parameter.

### Return type

[**Vec<models::PendingBoardInfo>**](PendingBoardInfo.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)


## prepare_review

> serde_json::Value prepare_review(board_request)


Prepare an unsigned funding transaction. Returns a 60-second request ID, board amount, net Ark amount, network fee, boarding fee and recovery reserve. Does not sign or broadcast.

### Parameters


Name | Type | Description  | Required | Notes
------------- | ------------- | ------------- | ------------- | -------------
**board_request** | [**BoardRequest**](BoardRequest.md) |  | [required] |

### Return type

[**serde_json::Value**](serde_json::Value.md)

### Authorization

[bearer](../README.md#bearer)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)
