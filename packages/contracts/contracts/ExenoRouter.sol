// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "erc-payable-token/contracts/token/ERC1363/ERC1363.sol";
import "./Router.sol";

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

contract ExenoRouter is Router {
  uint256 public constant BASE_LIQUIDITY = 1000 ether;
  address public rootAssetId;
  ChildAsset public childAsset;

  constructor(address _routerFactory)
    Router(_routerFactory)
  {}

  function initRootAsset(address _rootAssetId) 
    external onlyOwner
  {
    require(rootAssetId == address(0x0), "ROOT_ASSET_ALREADY_INITIALIZED");
    LibAsset.transferFromERC20(_rootAssetId, msg.sender, address(this), BASE_LIQUIDITY);
    rootAssetId = _rootAssetId;
  }

  function initChildAsset()
    external onlyOwner
  {
    require(address(childAsset) == address(0x0), "CHILD_ASSET_ALREADY_INITIALIZED");
    childAsset = new ChildAsset(BASE_LIQUIDITY);
    childAsset.approve(address(transactionManager), BASE_LIQUIDITY);
    transactionManager.addLiquidity(BASE_LIQUIDITY, address(childAsset));
  }

  function prepare(
    ITransactionManager.PrepareArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  )
    public payable override returns(ITransactionManager.TransactionData memory)
  {
    ITransactionManager.TransactionData memory txData = super.prepare(
      args,
      routerRelayerFeeAsset,
      routerRelayerFee,
      signature
    );
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
    public override returns(ITransactionManager.TransactionData memory)
  {
    ITransactionManager.TransactionData memory txData = super.fulfill(
      args,
      routerRelayerFeeAsset,
      routerRelayerFee,
      signature
    );
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
    public override returns(ITransactionManager.TransactionData memory)
  {
    ITransactionManager.TransactionData memory txData = super.cancel(
      args,
      routerRelayerFeeAsset,
      routerRelayerFee,
      signature
    );
    if (args.txData.receivingAssetId == address(childAsset)) {
      transactionManager.removeLiquidity(args.txData.amount, address(childAsset), payable(this));
      childAsset.burn(args.txData.amount);
    }
    return txData;
  }
}
