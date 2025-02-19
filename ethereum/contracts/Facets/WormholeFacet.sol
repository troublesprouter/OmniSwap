// SPDX-License-Identifier: GPLv3
pragma solidity 0.8.13;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../Libraries/LibDiamond.sol";
import "../Libraries/LibBytes.sol";
import "../Libraries/LibCross.sol";
import "../Interfaces/ISo.sol";
import "../Interfaces/ILibPrice.sol";
import "../Helpers/Swapper.sol";
import "../Interfaces/IWormholeBridge.sol";
import "../Interfaces/ILibSoFee.sol";

/// @title Wormhole Facet
/// @author OmniBTC
/// @notice Provides functionality for bridging through Wormhole
contract WormholeFacet is Swapper {
    using SafeMath for uint256;
    using LibBytes for bytes;

    /// Storage ///

    bytes32 internal constant NAMESPACE =
        hex"d4ca4302bca26785486b2ceec787497a9cf992c36dcf57c306a00c1f88154623"; // keccak256("com.so.facets.wormhole")

    uint256 public constant RAY = 1e27;

    struct Storage {
        address tokenBridge;
        uint16 srcWormholeChainId;
        uint256 actualReserve; // [RAY]
        uint256 estimateReserve; // [RAY]
        mapping(uint16 => uint256) dstBaseGas;
        mapping(uint16 => uint256) dstGasPerBytes;
    }

    /// Events ///

    event InitWormholeEvent(address tokenBridge, uint16 srcWormholeChainId);
    event UpdateWormholeReserve(uint256 actualReserve, uint256 estimateReserve);
    event UpdateWormholeGas(
        uint16 dstWormholeChainId,
        uint256 baseGas,
        uint256 gasPerBytes
    );
    event TransferFromWormhole(
        uint16 srcWormholeChainId,
        uint16 dstWormholeChainId,
        uint64 sequence
    );

    /// Types ///

    struct NormalizedWormholeData {
        uint16 dstWormholeChainId;
        uint256 dstMaxGasPriceInWeiForRelayer;
        uint256 wormholeFee;
        bytes dstSoDiamond;
    }

    struct CacheSrcSoSwap {
        bool flag;
        uint256 fee;
        bool hasSourceSwap;
        bool hasDestinationSwap;
        uint256 bridgeAmount;
        address bridgeAddress;
        uint256 returnValue;
        uint256 dstMaxGas;
        bytes payload;
    }

    struct CacheCheck {
        uint256 ratio;
        uint256 srcFee;
        uint256 dstFee;
        uint256 userInput;
        uint256 dstMaxGasForRelayer;
        bool flag;
        uint256 returnValue;
        uint256 consumeValue;
    }

    struct CachePayload {
        uint256 dstMaxGasPrice;
        uint256 dstMaxGas;
        ISo.NormalizedSoData soData;
        LibSwap.NormalizedSwapData[] swapDataDst;
    }

    /// Init Methods ///

    /// @dev Set wormhole tokenbridge address and current wormhole chain id
    /// @param tokenBridge wormhole tokenbridge address
    /// @param wormholeChainId current wormhole chain id
    function initWormhole(address tokenBridge, uint16 wormholeChainId)
        external
    {
        LibDiamond.enforceIsContractOwner();
        Storage storage s = getStorage();
        s.tokenBridge = tokenBridge;
        s.srcWormholeChainId = wormholeChainId;
        emit InitWormholeEvent(tokenBridge, wormholeChainId);
    }

    /// @dev Sets the scale to be used when calculating relayer fees
    /// @param actualReserve percentage of actual use of relayer fees, expressed as RAY
    /// @param estimateReserve estimated percentage of use at the time of call, expressed as RAY
    function setWormholeReserve(uint256 actualReserve, uint256 estimateReserve)
        external
    {
        LibDiamond.enforceIsContractOwner();
        Storage storage s = getStorage();
        s.actualReserve = actualReserve;
        s.estimateReserve = estimateReserve;
        emit UpdateWormholeReserve(actualReserve, estimateReserve);
    }

    /// @dev Set the minimum gas to be spent on the target chain
    /// @param dstWormholeChainId destination chain wormhole chain id
    /// @param baseGas basic fee for a successful transaction
    /// @param gasPerBytes the amount of gas needed to transfer each byte of the payload
    function setWormholeGas(
        uint16 dstWormholeChainId,
        uint256 baseGas,
        uint256 gasPerBytes
    ) external {
        LibDiamond.enforceIsContractOwner();
        Storage storage s = getStorage();
        s.dstBaseGas[dstWormholeChainId] = baseGas;
        s.dstGasPerBytes[dstWormholeChainId] = gasPerBytes;
        emit UpdateWormholeGas(dstWormholeChainId, baseGas, gasPerBytes);
    }

    /// External Methods ///

    /// @dev Bridge tokens via wormhole
    /// @param soDataNo data for tracking cross-chain transactions and a
    ///                 portion of the accompanying cross-chain messages
    /// @param swapDataSrcNo contains a set of data required for Swap
    ///                     transactions on the source chain side
    /// @param wormholeDataNo data used to call Wormhole's tokenbridge for swap
    /// @param swapDataDstNo contains a set of Swap transaction data executed
    ///                     on the target chain.
    function soSwapViaWormhole(
        ISo.NormalizedSoData calldata soDataNo,
        LibSwap.NormalizedSwapData[] calldata swapDataSrcNo,
        NormalizedWormholeData calldata wormholeDataNo,
        LibSwap.NormalizedSwapData[] calldata swapDataDstNo
    ) external payable {
        require(msg.value == wormholeDataNo.wormholeFee, "Fee error");

        CacheSrcSoSwap memory cache;

        ISo.SoData memory soData = LibCross.denormalizeSoData(soDataNo);
        LibSwap.SwapData[] memory swapDataSrc = LibCross.denormalizeSwapData(
            swapDataSrcNo
        );

        (
            cache.flag,
            cache.fee,
            cache.returnValue,
            cache.dstMaxGas
        ) = checkRelayerFee(soDataNo, wormholeDataNo, swapDataDstNo);

        require(cache.flag, "Check fail");
        // return the redundant msg.value
        if (cache.returnValue > 0) {
            LibAsset.transferAsset(
                LibAsset.NATIVE_ASSETID,
                payable(msg.sender),
                cache.returnValue
            );
        }

        if (cache.fee > 0) {
            LibAsset.transferAsset(
                LibAsset.NATIVE_ASSETID,
                payable(LibDiamond.contractOwner()),
                cache.fee
            );
        }
        if (!LibAsset.isNativeAsset(soData.sendingAssetId)) {
            LibAsset.depositAsset(soData.sendingAssetId, soData.amount);
        }
        if (swapDataSrc.length == 0) {
            cache.bridgeAddress = soData.sendingAssetId;
            cache.bridgeAmount = soData.amount;
            cache.hasSourceSwap = false;
        } else {
            require(
                soData.amount == swapDataSrc[0].fromAmount,
                "soData and swapDataSrc amount not match!"
            );
            cache.bridgeAmount = this.executeAndCheckSwaps(soData, swapDataSrc);
            cache.bridgeAddress = swapDataSrc[swapDataSrc.length - 1]
                .receivingAssetId;
            cache.hasSourceSwap = true;
        }

        cache.payload = encodeWormholePayload(
            wormholeDataNo.dstMaxGasPriceInWeiForRelayer,
            cache.dstMaxGas,
            soDataNo,
            swapDataDstNo
        );

        if (swapDataDstNo.length > 0) {
            cache.hasDestinationSwap = true;
        }

        /// start bridge
        _startBridge(
            wormholeDataNo,
            cache.bridgeAddress,
            cache.bridgeAmount,
            cache.payload
        );

        emit ISo.SoTransferStarted(
            soData.transactionId,
            "Wormhole",
            cache.hasSourceSwap,
            cache.hasDestinationSwap,
            soData
        );
    }

    /// @notice Receiving chain's native tokens crossed over from other chains
    /// @dev for relayer automatic call
    function completeTransferAndUnwrapETHWithPayload(bytes memory encodeVm)
        external
    {
        completeSoSwap(encodeVm);
    }

    /// @notice Receiving erc20 tokens crossed over from other chains
    /// @dev for relayer automatic call
    function completeTransferWithPayload(bytes memory encodeVm) external {
        completeSoSwap(encodeVm);
    }

    /// @notice Users can manually call for cross-chain tokens
    function completeSoSwap(bytes memory encodeVm) public {
        Storage storage s = getStorage();
        address bridge = s.tokenBridge;

        bytes memory payload = IWormholeBridge(bridge)
            .completeTransferWithPayload(encodeVm);

        IWormholeBridge.TransferWithPayload
            memory wormholePayload = IWormholeBridge(bridge)
                .parseTransferWithPayload(payload);

        (
            ,
            ,
            ISo.NormalizedSoData memory soDataNo,
            LibSwap.NormalizedSwapData[] memory swapDataDstNo
        ) = decodeWormholePayload(wormholePayload.payload);

        ISo.SoData memory soData = LibCross.denormalizeSoData(soDataNo);
        LibSwap.SwapData[] memory swapDataDst = LibCross.denormalizeSwapData(
            swapDataDstNo
        );

        address tokenAddress;
        bool isOriginChain;
        if (wormholePayload.tokenChain == IWormholeBridge(bridge).chainId()) {
            tokenAddress = address(
                uint160(uint256(wormholePayload.tokenAddress))
            );
            isOriginChain = true;
        } else {
            tokenAddress = IWormholeBridge(bridge).wrappedAsset(
                wormholePayload.tokenChain,
                wormholePayload.tokenAddress
            );
        }

        uint256 amount = LibAsset.getOwnBalance(tokenAddress);
        require(amount > 0, "amount > 0");

        IWETH weth = IWormholeBridge(bridge).WETH();

        if (isOriginChain && address(weth) == tokenAddress) {
            weth.withdraw(amount);
            tokenAddress = LibAsset.NATIVE_ASSETID;
        }

        uint256 soFee = getSoFee(amount);
        if (soFee > 0 && soFee < amount) {
            amount = amount.sub(soFee);
        }

        if (swapDataDst.length == 0) {
            require(tokenAddress == soData.receivingAssetId, "token error");
            if (soFee > 0) {
                LibAsset.transferAsset(
                    soData.receivingAssetId,
                    payable(LibDiamond.contractOwner()),
                    soFee
                );
            }
            LibAsset.transferAsset(
                soData.receivingAssetId,
                soData.receiver,
                amount
            );
            emit SoTransferCompleted(
                soData.transactionId,
                soData.receivingAssetId,
                soData.receiver,
                amount,
                block.timestamp,
                soData
            );
        } else {
            if (soFee > 0) {
                LibAsset.transferAsset(
                    swapDataDst[0].sendingAssetId,
                    payable(LibDiamond.contractOwner()),
                    soFee
                );
            }
            require(
                swapDataDst[0].sendingAssetId == tokenAddress,
                "token error"
            );

            swapDataDst[0].fromAmount = amount;

            address correctSwap = appStorage.correctSwapRouterSelectors;

            if (correctSwap != address(0)) {
                swapDataDst[0].callData = ICorrectSwap(correctSwap).correctSwap(
                    swapDataDst[0].callData,
                    swapDataDst[0].fromAmount
                );
            }

            try this.executeAndCheckSwaps(soData, swapDataDst) returns (
                uint256 amountFinal
            ) {
                LibAsset.transferAsset(
                    swapDataDst[swapDataDst.length - 1].receivingAssetId,
                    soData.receiver,
                    amountFinal
                );
                emit SoTransferCompleted(
                    soData.transactionId,
                    soData.receivingAssetId,
                    soData.receiver,
                    amountFinal,
                    block.timestamp,
                    soData
                );
            } catch Error(string memory revertReason) {
                LibAsset.transferAsset(
                    soData.receivingAssetId,
                    soData.receiver,
                    amount
                );
                emit SoTransferFailed(
                    soData.transactionId,
                    revertReason,
                    bytes(""),
                    soData
                );
            } catch (bytes memory returnData) {
                LibAsset.transferAsset(
                    soData.receivingAssetId,
                    soData.receiver,
                    amount
                );
                emit SoTransferFailed(
                    soData.transactionId,
                    "",
                    returnData,
                    soData
                );
            }
        }
    }

    /// @dev Estimate the minimum gas to be consumed at the target chain
    /// @param soData used to encode into payload
    /// @param wormholeData used to encode into payload
    /// @param swapDataDst used to encode into payload
    function estimateCompleteSoSwapGas(
        ISo.NormalizedSoData calldata soData,
        NormalizedWormholeData calldata wormholeData,
        LibSwap.NormalizedSwapData[] calldata swapDataDst
    ) public view returns (uint256) {
        bytes memory payload = encodeWormholePayload(
            wormholeData.dstMaxGasPriceInWeiForRelayer,
            0,
            soData,
            swapDataDst
        );
        Storage storage s = getStorage();
        return
            s.dstBaseGas[wormholeData.dstWormholeChainId].add(
                s.dstGasPerBytes[wormholeData.dstWormholeChainId].mul(
                    payload.length
                )
            );
    }

    /// @dev Check if enough value is passed in for payment
    function checkRelayerFee(
        ISo.NormalizedSoData calldata soData,
        NormalizedWormholeData calldata wormholeData,
        LibSwap.NormalizedSwapData[] calldata swapDataDst
    )
        public
        returns (
            bool,
            uint256,
            uint256,
            uint256
        )
    {
        CacheCheck memory data;
        Storage storage s = getStorage();
        ILibPrice oracle = ILibPrice(
            appStorage.gatewaySoFeeSelectors[s.tokenBridge]
        );
        data.ratio = oracle.updatePriceRatio(wormholeData.dstWormholeChainId);
        data.dstMaxGasForRelayer = estimateCompleteSoSwapGas(
            soData,
            wormholeData,
            swapDataDst
        );

        data.dstFee = data.dstMaxGasForRelayer.mul(
            wormholeData.dstMaxGasPriceInWeiForRelayer
        );
        data.srcFee = data
            .dstFee
            .mul(data.ratio)
            .div(oracle.RAY())
            .mul(s.actualReserve)
            .div(RAY);

        if (LibAsset.isNativeAsset(soData.sendingAssetId.toAddress(0))) {
            data.userInput = soData.amount;
        }
        data.consumeValue = IWormholeBridge(s.tokenBridge)
            .wormhole()
            .messageFee()
            .add(data.userInput)
            .add(data.srcFee);
        if (data.consumeValue <= wormholeData.wormholeFee) {
            data.flag = true;
            data.returnValue = wormholeData.wormholeFee.sub(data.consumeValue);
        }
        return (
            data.flag,
            data.srcFee,
            data.returnValue,
            data.dstMaxGasForRelayer
        );
    }

    /// @dev Estimated relayer cost, which needs to be paid by the user
    function estimateRelayerFee(
        ISo.NormalizedSoData calldata soData,
        NormalizedWormholeData calldata wormholeData,
        LibSwap.NormalizedSwapData[] calldata swapDataDst
    ) external view returns (uint256) {
        Storage storage s = getStorage();
        ILibPrice oracle = ILibPrice(
            appStorage.gatewaySoFeeSelectors[s.tokenBridge]
        );
        (uint256 ratio, ) = oracle.getPriceRatio(
            wormholeData.dstWormholeChainId
        );
        uint256 dstMaxGasForRelayer = estimateCompleteSoSwapGas(
            soData,
            wormholeData,
            swapDataDst
        );
        uint256 dstFee = dstMaxGasForRelayer.mul(
            wormholeData.dstMaxGasPriceInWeiForRelayer
        );
        uint256 srcFee = dstFee
            .mul(ratio)
            .div(oracle.RAY())
            .mul(s.estimateReserve)
            .div(RAY);
        return srcFee;
    }

    function getWormholeMessageFee() public view returns (uint256) {
        Storage storage s = getStorage();
        return IWormholeBridge(s.tokenBridge).wormhole().messageFee();
    }

    /// @dev Get so fee
    function getSoFee(uint256 amount) public view returns (uint256) {
        Storage storage s = getStorage();
        address soFee = appStorage.gatewaySoFeeSelectors[s.tokenBridge];
        if (soFee == address(0x0)) {
            return 0;
        } else {
            return ILibSoFee(soFee).getFees(amount);
        }
    }

    function encodeNormalizedWormholeData(NormalizedWormholeData memory data)
        public
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                data.dstWormholeChainId,
                data.dstMaxGasPriceInWeiForRelayer,
                data.wormholeFee,
                uint64(data.dstSoDiamond.length),
                data.dstSoDiamond
            );
    }

    function decodeNormalizedWormholeData(bytes memory wormholeData)
        public
        pure
        returns (NormalizedWormholeData memory)
    {
        NormalizedWormholeData memory data;
        uint256 index;
        uint256 nextLen;

        nextLen = 2;
        data.dstWormholeChainId = wormholeData.toUint16(index);
        index += nextLen;

        nextLen = 32;
        data.dstMaxGasPriceInWeiForRelayer = wormholeData.toUint256(index);
        index += nextLen;

        nextLen = 32;
        data.wormholeFee = wormholeData.toUint256(index);
        index += nextLen;

        nextLen = uint256(wormholeData.toUint64(index));
        index += 8;
        data.dstSoDiamond = wormholeData.slice(index, nextLen);
        index += nextLen;

        require(index == wormholeData.length, "Length error");

        return data;
    }

    function encodeWormholePayload(
        uint256 dstMaxGasPrice,
        uint256 dstMaxGas,
        ISo.NormalizedSoData memory soData,
        LibSwap.NormalizedSwapData[] memory swapDataDst
    ) public pure returns (bytes memory) {
        bytes memory d1 = LibCross.encodeNormalizedSoData(soData);
        bytes memory d2 = LibCross.encodeNormalizedSwapData(swapDataDst);
        if (d2.length > 0) {
            return
                abi.encodePacked(
                    dstMaxGasPrice,
                    dstMaxGas,
                    uint64(d1.length),
                    d1,
                    uint64(d2.length),
                    d2
                );
        } else {
            return
                abi.encodePacked(
                    dstMaxGasPrice,
                    dstMaxGas,
                    uint64(d1.length),
                    d1
                );
        }
    }

    function decodeWormholePayload(bytes memory wormholeData)
        public
        pure
        returns (
            uint256,
            uint256,
            ISo.NormalizedSoData memory,
            LibSwap.NormalizedSwapData[] memory
        )
    {
        uint256 index;
        uint256 nextLen;
        CachePayload memory data;

        nextLen = 32;
        data.dstMaxGasPrice = uint256(wormholeData.toUint256(index));
        index += nextLen;

        nextLen = 32;
        data.dstMaxGas = uint256(wormholeData.toUint256(index));
        index += nextLen;

        nextLen = uint256(wormholeData.toUint64(index));
        index += 8;
        data.soData = LibCross.decodeNormalizedSoData(
            wormholeData.slice(index, nextLen)
        );
        index += nextLen;

        if (index < wormholeData.length) {
            nextLen = uint256(wormholeData.toUint64(index));
            index += 8;
            data.swapDataDst = LibCross.decodeNormalizedSwapData(
                wormholeData.slice(index, nextLen)
            );
            index += nextLen;
        }

        require(index == wormholeData.length, "Length error");
        return (
            data.dstMaxGasPrice,
            data.dstMaxGas,
            data.soData,
            data.swapDataDst
        );
    }

    /// Internal Methods ///

    function _startBridge(
        NormalizedWormholeData calldata wormholeData,
        address token,
        uint256 amount,
        bytes memory payload
    ) internal {
        Storage storage s = getStorage();
        address bridge = s.tokenBridge;

        bytes32 dstSoDiamond;
        if (wormholeData.dstSoDiamond.length == 20) {
            dstSoDiamond = bytes32(
                uint256(uint160(wormholeData.dstSoDiamond.toAddress(0)))
            );
        } else {
            dstSoDiamond = wormholeData.dstSoDiamond.toBytes32(0);
        }

        uint64 sequence;
        uint256 wormholeMsgFee = getWormholeMessageFee();
        if (LibAsset.isNativeAsset(token)) {
            sequence = IWormholeBridge(bridge).wrapAndTransferETHWithPayload{
                value: amount + wormholeMsgFee
            }(wormholeData.dstWormholeChainId, dstSoDiamond, 0, payload);
        } else {
            LibAsset.maxApproveERC20(IERC20(token), bridge, amount);
            sequence = IWormholeBridge(bridge).transferTokensWithPayload{
                value: wormholeMsgFee
            }(
                token,
                amount,
                wormholeData.dstWormholeChainId,
                dstSoDiamond,
                0,
                payload
            );
        }

        emit TransferFromWormhole(
            s.srcWormholeChainId,
            wormholeData.dstWormholeChainId,
            sequence
        );
    }

    /// Private Methods ///

    /// @dev fetch local storage
    function getStorage() private pure returns (Storage storage s) {
        bytes32 namespace = NAMESPACE;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            s.slot := namespace
        }
    }
}
