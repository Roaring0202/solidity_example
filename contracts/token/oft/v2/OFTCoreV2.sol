// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../lzApp/NonblockingLzApp.sol";
import "../../../util/ExcessivelySafeCall.sol";
import "../composable/IOFTReceiver.sol";
import "./ICommonOFT.sol";

abstract contract OFTCoreV2 is NonblockingLzApp, ICommonOFT {
    using BytesLib for bytes;
    using ExcessivelySafeCall for address;

    uint public constant NO_EXTRA_GAS = 0;

    // packet type
    uint8 public constant PT_SEND = 0;
    uint8 public constant PT_SEND_AND_CALL = 1;

    uint8 public immutable sharedDecimals;

    bool public useCustomAdapterParams;
    
    mapping(uint16 => mapping(bytes => mapping(uint64 => bytes32))) public failedOFTReceivedMessages;

    /**
     * @dev Emitted when `_amount` tokens are moved from the `_sender` to (`_dstChainId`, `_toAddress`)
     * `_nonce` is the outbound nonce
     */
    event SendToChain(uint16 indexed _dstChainId, address indexed _from, bytes _toAddress, uint _amount);

    /**
     * @dev Emitted when `_amount` tokens are received from `_srcChainId` into the `_toAddress` on the local chain.
     * `_nonce` is the inbound nonce.
     */
    event ReceiveFromChain(uint16 indexed _srcChainId, address indexed _to, uint _amount);

    event SetUseCustomAdapterParams(bool _useCustomAdapterParams);

    event CallOFTReceivedFailure(uint16 indexed _srcChainId, bytes _srcAddress, uint64 _nonce, bytes _from, address indexed _to, uint _amount, bytes _payload, bytes _reason);

    event CallOFTReceivedSuccess(uint16 indexed _srcChainId, bytes _srcAddress, uint64 _nonce, bytes32 _hash);

    event RetryOFTReceivedSuccess(bytes32 _messageHash);

    event NonContractAddress(address _address);

    event InvalidReceiver(bytes _receiver);

    // _sharedDecimals should be the minimum decimals on all chains
    constructor(uint8 _sharedDecimals, address _lzEndpoint) NonblockingLzApp(_lzEndpoint) {
        sharedDecimals = _sharedDecimals;
    }

    // todo: lzapp?
    /************************************************************************
    * owner functions
    ************************************************************************/
    function setUseCustomAdapterParams(bool _useCustomAdapterParams) public virtual onlyOwner {
        useCustomAdapterParams = _useCustomAdapterParams;
        emit SetUseCustomAdapterParams(_useCustomAdapterParams);
    }

    /************************************************************************
    * internal functions
    ************************************************************************/
    function _estimateSendFee(uint16 _dstChainId, bytes calldata _toAddress, uint _amount, bool _useZro, bytes calldata _adapterParams) internal view virtual returns (uint nativeFee, uint zroFee) {
        // mock the payload for sendFrom()
        bytes memory payload = _encodeSendPayload(_toAddress, _ld2sd(_amount));
        return lzEndpoint.estimateFees(_dstChainId, address(this), payload, _useZro, _adapterParams);
    }

    function _estimateSendAndCallFee(uint16 _dstChainId, bytes calldata _toAddress, uint _amount, bytes calldata _payload, uint64 _dstGasForCall, bool _useZro, bytes calldata _adapterParams) internal view virtual returns (uint nativeFee, uint zroFee) {
        // mock the payload for sendAndCall()
        bytes memory payload = _encodeSendAndCallPayload(msg.sender, _toAddress, _ld2sd(_amount), _payload, _dstGasForCall);
        return lzEndpoint.estimateFees(_dstChainId, address(this), payload, _useZro, _adapterParams);
    }

    function _retryOFTReceived(uint16 _srcChainId, bytes calldata _srcAddress, uint64 _nonce, bytes calldata _from, address _to, uint _amount, bytes calldata _payload) internal virtual {
        bytes32 msgHash = failedOFTReceivedMessages[_srcChainId][_srcAddress][_nonce];
        require(msgHash != bytes32(0), "OFTCore: no failed message to retry");

        bytes32 hash = keccak256(abi.encode(_from, _to, _amount, _payload));
        require(hash == msgHash, "OFTCore: failed message hash mismatch");

        delete failedOFTReceivedMessages[_srcChainId][_srcAddress][_nonce];

        IERC20(token()).transfer(_to, _amount);
        IOFTReceiver(_to).onOFTReceived(_srcChainId, _srcAddress, _nonce, _from, _amount, _payload);

        emit RetryOFTReceivedSuccess(hash);
    }

    function _nonblockingLzReceive(uint16 _srcChainId, bytes memory _srcAddress, uint64 _nonce, bytes memory _payload) internal virtual override {
        uint8 packetType = _payload.toUint8(0);

        if (packetType == PT_SEND) {
            _sendAck(_srcChainId, _srcAddress, _nonce, _payload);
        } else if (packetType == PT_SEND_AND_CALL) {
            _sendAndCallAck(_srcChainId, _srcAddress, _nonce, _payload);
        } else {
            revert("OFTCore: unknown packet type");
        }
    }

    function _send(address _from, uint16 _dstChainId, bytes memory _toAddress, uint _amount, address payable _refundAddress, address _zroPaymentAddress, bytes memory _adapterParams) internal virtual returns (uint amount) {
        _checkAdapterParams(_dstChainId, PT_SEND, _adapterParams, NO_EXTRA_GAS);

        (amount,) = _removeDust(_amount);
        amount = _debitFrom(_from, _dstChainId, _toAddress, amount);

        bytes memory lzPayload = _encodeSendPayload(_toAddress, _ld2sd(amount));
        _lzSend(_dstChainId, lzPayload, _refundAddress, _zroPaymentAddress, _adapterParams, msg.value);

        emit SendToChain(_dstChainId, _from, _toAddress, amount);
    }

    function _sendAck(uint16 _srcChainId, bytes memory, uint64, bytes memory _payload) internal virtual {
        (bytes memory toAddress, uint64 amountSD) = _decodeSendPayload(_payload);
        (bool isValid, address to) = _safeConvertReceiverAddress(toAddress);
        if (!isValid) {
            emit InvalidReceiver(toAddress);
        }

        uint amount = _sd2ld(amountSD);
        amount = _creditTo(_srcChainId, to, amount);
        emit ReceiveFromChain(_srcChainId, to, amount);
    }

    function _sendAndCall(address _from, uint16 _dstChainId, bytes memory _toAddress, uint _amount, bytes calldata _payload, uint64 _dstGasForCall, address payable _refundAddress, address _zroPaymentAddress, bytes memory _adapterParams) internal virtual returns (uint amount) {
        _checkAdapterParams(_dstChainId, PT_SEND_AND_CALL, _adapterParams, _dstGasForCall);

        (amount,) = _removeDust(_amount);
        amount = _debitFrom(_from, _dstChainId, _toAddress, amount);

        // encode the msg.sender into the payload instead of _from
        bytes memory lzPayload = _encodeSendAndCallPayload(msg.sender, _toAddress, _ld2sd(amount), _payload, _dstGasForCall);
        _lzSend(_dstChainId, lzPayload, _refundAddress, _zroPaymentAddress, _adapterParams, msg.value);

        emit SendToChain(_dstChainId, _from, _toAddress, amount);
    }

    function _sendAndCallAck(uint16 _srcChainId, bytes memory _srcAddress, uint64 _nonce, bytes memory _payload) internal virtual {
        (bytes memory from, bytes memory toAddress, uint64 amountSD, bytes memory payload, uint64 gasForCall) = _decodeSendAndCallPayload(_payload);
        (bool isValid, address to) = _safeConvertReceiverAddress(toAddress);

        uint amount = _sd2ld(amountSD);
        amount = _creditTo(_srcChainId, address(this), amount);
        emit ReceiveFromChain(_srcChainId, to, amount);

        if (!isValid) {
            emit InvalidReceiver(toAddress);
            return;
        }

        if (!_isContract(to)) {
            emit NonContractAddress(to);
            return;
        }

        try this.safeCallOnOFTReceived(_srcChainId, _srcAddress, _nonce, from, to, amount, payload, gasForCall) {
            bytes32 hash = keccak256(abi.encode(from, to, amount, payload));
            emit CallOFTReceivedSuccess(_srcChainId, _srcAddress, _nonce, hash);
        } catch(bytes memory reason) {
            failedOFTReceivedMessages[_srcChainId][_srcAddress][_nonce] = keccak256(abi.encode(from, to, amount, payload));
            emit CallOFTReceivedFailure(_srcChainId, _srcAddress, _nonce, from, to, amount, payload, reason);
        }
    }

    function safeCallOnOFTReceived(uint16 _srcChainId, bytes memory _srcAddress, uint64 _nonce, bytes memory _from, address _to, uint _amount, bytes memory _payload, uint64 _gasForCall) public virtual {
        require(_msgSender() == address(this), "OFTCore: caller must be OFTCore");

        IERC20(token()).transfer(_to, _amount);
        (bool success, bytes memory reason) = _to.excessivelySafeCall(_gasForCall, 150, abi.encodeWithSelector(IOFTReceiver.onOFTReceived.selector, _srcChainId, _srcAddress, _nonce, _from, _amount, _payload));

        require(success, string(reason));
    }

    function _safeConvertReceiverAddress(bytes memory _address) internal view virtual returns (bool, address) {
        if (_address.length != 20) {
            return (false, address(0xdead));
        }

        address to = _address.toAddress(0);
        if (to == address(0)) {
            to = address(0xdead);
        }
        return (true, to);
    }

    function _isContract(address _account) internal view returns (bool) {
        return _account.code.length > 0;
    }

    function _checkAdapterParams(uint16 _dstChainId, uint16 _pkType, bytes memory _adapterParams, uint _extraGas) internal virtual {
        if (useCustomAdapterParams) {
            _checkGasLimit(_dstChainId, _pkType, _adapterParams, _extraGas);
        } else {
            require(_adapterParams.length == 0, "OFTCore: _adapterParams must be empty.");
        }
    }

    function _ld2sd(uint _amount) internal virtual view returns (uint64) {
        uint amountSD = _amount / _ld2sdRate();
        require(amountSD <= type(uint64).max, "OFTCore: amountSD overflow");
        return uint64(amountSD);
    }

    function _sd2ld(uint64 _amountSD) internal virtual view returns (uint) {
        return _amountSD * _ld2sdRate();
    }

    function _removeDust(uint _amount) internal virtual view returns (uint amountAfter, uint dust) {
        dust = _amount % _ld2sdRate();
        amountAfter = _amount - dust;
    }

    function _encodeSendPayload(bytes memory _toAddress, uint64 _amountSD) internal virtual view returns (bytes memory) {
        return abi.encodePacked(PT_SEND, uint8(_toAddress.length), _toAddress, _amountSD);
    }

    function _decodeSendPayload(bytes memory _payload) internal virtual view returns (bytes memory to, uint64 amountSD) {
        require(_payload.toUint8(0) == PT_SEND, "OFTCore: invalid payload");

        uint8 toAddressSize = _payload.toUint8(1);
        to = _payload.slice(2, toAddressSize);
        amountSD = _payload.toUint64(2 + toAddressSize);
    }

    function _encodeSendAndCallPayload(address _from, bytes memory _toAddress, uint64 _amountSD, bytes calldata _payload, uint64 _dstGasForCall) internal virtual view returns (bytes memory) {
        return abi.encodePacked(
            PT_SEND_AND_CALL,
            uint8(_toAddress.length),
            _toAddress,
            _amountSD,
            uint8(20),
            _from,
            uint8(_payload.length),
            _payload,
            _dstGasForCall
        );
    }

    function _decodeSendAndCallPayload(bytes memory _payload) internal virtual view returns (bytes memory from, bytes memory to, uint64 amountSD, bytes memory payload, uint64 dstGasForCall) {
        require(_payload.toUint8(0) == PT_SEND_AND_CALL, "OFTCore: invalid payload");

        // to address
        uint8 toAddressSize = _payload.toUint8(1);
        to = _payload.slice(2, toAddressSize);

        // token amount
        amountSD = _payload.toUint64(2 + toAddressSize);

        // from address
        uint8 fromAddressSize = _payload.toUint8(10 + toAddressSize);
        from = _payload.slice(11 + toAddressSize, fromAddressSize);

        // payload
        uint8 payloadSize = _payload.toUint8(11 + toAddressSize + fromAddressSize);
        payload = _payload.slice(12 + toAddressSize + fromAddressSize, payloadSize);

        // dst gas
        dstGasForCall = _payload.toUint64(12 + toAddressSize + fromAddressSize + payloadSize);
    }

    function _debitFrom(address _from, uint16 _dstChainId, bytes memory _toAddress, uint _amount) internal virtual returns (uint);

    function _creditTo(uint16 _srcChainId, address _toAddress, uint _amount) internal virtual returns (uint);

    function _ld2sdRate() internal view virtual returns (uint);

    function circulatingSupply() public view virtual override returns (uint);

    function token() public view virtual override returns (address);
}
