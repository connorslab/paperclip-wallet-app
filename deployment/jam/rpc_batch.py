"""Bind the pinned RPC filter's batch replies to their reviewed request methods.

Node replies may arrive in any order. Internal IDs also disambiguate duplicate
client IDs; they never change RPC methods, parameters or wallet scope.
"""
import json
import math


def install(namespace):
    check_call = namespace['check_call']
    error_obj = namespace['error_obj']
    notification = namespace['_is_notification']
    wallet_lists = namespace['WALLET_LIST_METHODS']
    filter_wallet_list = namespace['filter_wallet_list']
    invalid = namespace['ERR_INVALID_REQUEST']
    internal = namespace['ERR_INTERNAL']
    denied = namespace['ERR_NOT_ALLOWED']

    def batch(self, calls, wallet, path):
        if not calls:
            return 200, error_obj(None, invalid, 'empty batch')
        reviewed, outgoing, expected = [], [], set()
        for index, call in enumerate(calls):
            verdict = check_call(call, wallet)
            method = call.get('method') if isinstance(call, dict) else None
            identity = call.get('id') if isinstance(call, dict) else None
            valid_id = (identity is None or type(identity) in (str, int)
                or (type(identity) is float and math.isfinite(identity)))
            if not valid_id:
                verdict = 'invalid request'
                call = {**call, 'id': None}
            if self.mode == 'record':
                self.record(method, wallet, verdict)
                if verdict != 'invalid request':
                    verdict = None
            if verdict is not None:
                self._log_denied(method, wallet, verdict)
            key = 'paperclip-rpc-' + str(index)
            reviewed.append((call, verdict, key))
            if verdict is None:
                if notification(call):
                    outgoing.append(call)
                else:
                    outgoing.append({**call, 'id': key})
                    expected.add(key)

        status, replies, matched = 200, {}, True
        if outgoing:
            status, data, _ = self.forward(path, json.dumps(outgoing).encode())
            try:
                if not data and not 200 <= status < 300:
                    raise ValueError('Unsuccessful empty response')
                values = [] if not expected and not data else json.loads(data)
                if not isinstance(values, list):
                    raise ValueError('Invalid batch response')
                for reply in values:
                    if (not isinstance(reply, dict) or type(reply.get('id')) is not str
                            or reply['id'] not in expected or reply['id'] in replies
                            or (reply.get('error') is None and 'result' not in reply)
                            or (reply.get('error') is not None and
                                (not isinstance(reply['error'], dict) or reply.get('result') is not None))):
                        raise ValueError('Unmatched batch response')
                    replies[reply['id']] = reply
                if set(replies) != expected:
                    raise ValueError('Incomplete batch response')
            except (ValueError, UnicodeDecodeError):
                # No response or raw error from an ambiguous batch may escape
                # method-specific filtering. Some calls may already have run.
                status, replies, matched = 502, {}, False

        result = []
        for call, verdict, key in reviewed:
            if notification(call):
                continue
            if verdict is not None:
                result.append(error_obj(call, invalid if verdict == 'invalid request' else denied,
                    'request not allowed by JoinBlaket RPC filter'))
            elif not matched:
                result.append(error_obj(call, internal,
                    'Node replies could not be matched. Check status before retrying.'))
            else:
                reply = {**replies[key], 'id': call.get('id')}
                if self.mode == 'enforce' and reply.get('error') is None and call['method'] in wallet_lists:
                    reply['result'] = filter_wallet_list(call['method'], reply.get('result'))
                result.append(reply)
        if not result:
            return (204 if matched else 502), b''
        return status, result

    namespace['Filter']._handle_batch = batch
