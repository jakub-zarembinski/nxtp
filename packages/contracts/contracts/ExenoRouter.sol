// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./lib/LibAsset.sol";
import "./interfaces/ITransactionManager.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "erc-payable-token/contracts/token/ERC1363/ERC1363.sol";

contract ChildAsset is Ownable, ERC1363 {
  string private constant NAME = "EXENO COIN";
  string private constant SYMBOL = "EXN";

  constructor(uint256 amount)
    ERC20(NAME, SYMBOL)
  {
    _mint(_msgSender(), amount);
  }

  function mint(uint256 amount)
    external onlyOwner
  {
    _mint(_msgSender(), amount);
  }

  function burn(uint256 amount)
    external onlyOwner
  {
    _burn(_msgSender(), amount);
  }
}

contract ExenoRouter is Ownable {
  uint256 public constant BASE_LIQUIDITY = 1000 ether;
  
  address public immutable routerFactory;

  ITransactionManager public transactionManager;

  ChildAsset public childAsset;

  address public rootAssetId;

  address public recipient;

  address public routerSigner;

  uint256 private chainId;

  struct SignedPrepareData {
    ITransactionManager.PrepareArgs args;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  struct SignedFulfillData {
    ITransactionManager.FulfillArgs args;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  struct SignedCancelData {
    ITransactionManager.CancelArgs args;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  struct SignedRemoveLiquidityData {
    uint256 amount;
    address assetId;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  event RelayerFeeAdded(address assetId, uint256 amount, address caller);
  event RelayerFeeRemoved(address assetId, uint256 amount, address caller);
  event RemoveLiquidity(
    uint256 amount, 
    address assetId,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee, 
    address caller
  );
  event Prepare(
    ITransactionManager.InvariantTransactionData invariantData,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    address caller
  );
  event Fulfill(
    ITransactionManager.TransactionData txData,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    address caller
  );
  event Cancel(
    ITransactionManager.TransactionData txData,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    address caller
  );

  constructor(address _routerFactory)
  {
    routerFactory = _routerFactory;
  }

  // Prevents from calling methods other than routerFactory contract
  modifier onlyViaFactory() {
    require(msg.sender == routerFactory, "ONLY_VIA_FACTORY");
    _;
  }

  function init(
    address _transactionManager,
    uint256 _chainId,
    address _routerSigner,
    address _recipient,
    address _owner
  )
    external onlyViaFactory
  {
    transactionManager = ITransactionManager(_transactionManager);
    chainId = _chainId;
    routerSigner = _routerSigner;
    recipient = _recipient;
    transferOwnership(_owner);
  }

  function initRootAsset(address _rootAssetId) 
    external onlyOwner
  {
    require(rootAssetId == address(0x0), "ROOT_ASSET_ALREADY_INITIALIZED");
    require(IERC20(_rootAssetId).allowance(msg.sender, address(this)) >= BASE_LIQUIDITY, "REQUIRED_ALLOWANCE_HAS_NOT_BEEN_MADE");
    rootAssetId = _rootAssetId;
    LibAsset.transferFromERC20(rootAssetId, msg.sender, address(this), BASE_LIQUIDITY);
    assert(this.getRootAssetLockedInAmount() >= BASE_LIQUIDITY);
  }

  function initChildAsset()
    external onlyOwner
  {
    require(address(childAsset) == address(0x0), "CHILD_ASSET_ALREADY_INITIALIZED");
    childAsset = new ChildAsset(BASE_LIQUIDITY);
    childAsset.approve(address(transactionManager), BASE_LIQUIDITY);
    transactionManager.addLiquidity(BASE_LIQUIDITY, address(childAsset));
  }

  function setRecipient(address _recipient)
    external onlyOwner
  {
    recipient = _recipient;
  }

  function setSigner(address _routerSigner)
    external onlyOwner
  {
    routerSigner = _routerSigner;
  }

  function addRelayerFee(uint256 amount, address assetId)
    external payable
  {
    // Sanity check: nonzero amounts
    require(amount > 0, "#RC_ARF:002");

    // Transfer funds to contract
    // Validate correct amounts are transferred
    if (LibAsset.isNativeAsset(assetId)) {
      require(msg.value == amount, "#RC_ARF:005");
    } else {
      require(msg.value == 0, "#RC_ARF:006");
      LibAsset.transferFromERC20(assetId, msg.sender, address(this), amount);
    }

    // Emit event
    emit RelayerFeeAdded(assetId, amount, msg.sender);
  }

  function getRootAssetLockedInAmount()
    external view returns(uint256)
  {
    if (rootAssetId == address(0x0)) {
      return 0;
    }
    return IERC20(rootAssetId).balanceOf(address(this));
  }

  function removeRelayerFee(uint256 amount, address assetId)
    external onlyOwner
  {
    // Sanity check: nonzero amounts
    require(amount > 0, "#RC_RRF:002");

    // Transfer funds from contract
    LibAsset.transferAsset(assetId, payable(recipient), amount);

    // Emit event
    emit RelayerFeeRemoved(assetId, amount, msg.sender);
  }

  function removeLiquidity(
    uint256 amount,
    address assetId,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  )
    external
  {
    if (msg.sender != routerSigner) {
      SignedRemoveLiquidityData memory payload = SignedRemoveLiquidityData({
        amount: amount,
        assetId: assetId,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_RL:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }

    emit RemoveLiquidity(amount, assetId, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    return transactionManager.removeLiquidity(amount, assetId, payable(recipient));
  }

  function prepare(
    ITransactionManager.PrepareArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  )
    external payable returns(ITransactionManager.TransactionData memory)
  {
    if (msg.sender != routerSigner) {
      SignedPrepareData memory payload = SignedPrepareData({
        args: args,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_P:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }

    emit Prepare(args.invariantData, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    ITransactionManager.TransactionData memory txData = transactionManager.prepare(args);

    if (args.invariantData.receivingAssetId == address(childAsset)) {
      childAsset.mint(args.amount);
      childAsset.approve(address(transactionManager), args.amount);
      transactionManager.addLiquidity(args.amount, address(childAsset));
    }
    return txData;
  }

  function fulfill(
    ITransactionManager.FulfillArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  )
    external returns(ITransactionManager.TransactionData memory)
  {
    if (msg.sender != routerSigner) {
      SignedFulfillData memory payload = SignedFulfillData({
        args: args,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_F:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }

    emit Fulfill(args.txData, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    ITransactionManager.TransactionData memory txData = transactionManager.fulfill(args);

    if (args.txData.sendingAssetId == address(childAsset)) {
      transactionManager.removeLiquidity(args.txData.amount, address(childAsset), payable(this));
      childAsset.burn(args.txData.amount);
    }
    return txData;
  }

  function cancel(
    ITransactionManager.CancelArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  )
    external returns(ITransactionManager.TransactionData memory)
  {
    if (msg.sender != routerSigner) {
      SignedCancelData memory payload = SignedCancelData({
        args: args,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_C:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }
    emit Cancel(args.txData, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    ITransactionManager.TransactionData memory txData = transactionManager.cancel(args);

    if (args.txData.receivingAssetId == address(childAsset)) {
      transactionManager.removeLiquidity(args.txData.amount, address(childAsset), payable(this));
      childAsset.burn(args.txData.amount);
    }
    return txData;
  }

  /**
   * @notice Holds the logic to recover the routerSigner from an encoded payload.
   *         Will hash and convert to an eth signed message.
   * @param encodedPayload The payload that was signed
   * @param signature The signature you are recovering the routerSigner from
   */
  function recoverSignature(bytes memory encodedPayload, bytes calldata signature)
    internal pure returns(address)
  {
    // Recover
    return ECDSA.recover(ECDSA.toEthSignedMessageHash(keccak256(encodedPayload)), signature);
  }

  receive() external payable {}
}